-- 006: analyst signal form (checked by the same rules) + Telegram notifications.

-- ---------- analyst submits a signal → automatic check → back office ----------
create or replace function public.analyst_submit_signal(
  p_symbol text, p_side text, p_order_type text,
  p_entry numeric, p_stop numeric, p_tp1 numeric, p_tp2 numeric,
  p_valid_hours integer default 12, p_note text default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare
  cfg jsonb := (select value from app_config where key = 'rules');
  hist jsonb := (select value from app_config where key = 'hist_' || p_symbol);
  d date := (now() at time zone 'UTC')::date;
  ctx record; buy boolean := p_side = 'BUY'; h1 boolean; risk numeric; ratio numeric; r1 numeric;
  reasons jsonb := '[]'; ok boolean; all_ok boolean := true; new_id bigint;
begin
  if coalesce(my_role(), 'client') not in ('analyst','manager','admin') then raise exception 'not allowed'; end if;
  if p_side not in ('BUY','SELL') then raise exception 'bad side'; end if;

  select * into ctx from engine_context(p_symbol, d);
  h1 := engine_h1_up(p_symbol, now());
  risk := abs(p_entry - p_stop);

  ok := case when buy then p_stop < p_entry and p_entry < p_tp1 else p_tp1 < p_entry and p_entry < p_stop end;
  reasons := reasons || jsonb_build_object('rule','levels_order','ok',ok,'detail','SL / entry / TP on the correct sides'); all_ok := all_ok and ok;

  ok := ctx.sma is not null and (ctx.prev_close > ctx.sma) = buy;
  reasons := reasons || jsonb_build_object('rule','daily_trend','ok',ok,'detail',
     format('daily trend is %s', case when ctx.sma is null then 'unknown' when ctx.prev_close > ctx.sma then 'UP' else 'DOWN' end)); all_ok := all_ok and ok;

  ok := h1 is not null and h1 = buy;
  reasons := reasons || jsonb_build_object('rule','h1_trend','ok',ok,'detail',
     format('H1 trend is %s', case when h1 is null then 'unknown' when h1 then 'UP' else 'DOWN' end)); all_ok := all_ok and ok;

  ratio := case when ctx.atr > 0 then risk / ctx.atr end;
  ok := ratio between 0.25 and 1.2;
  reasons := reasons || jsonb_build_object('rule','stop_size','ok',coalesce(ok,false),'detail',
     format('stop = %s x daily ATR (allowed 0.25–1.2)', round(ratio, 2))); all_ok := all_ok and coalesce(ok,false);

  r1 := case when risk > 0 then abs(p_tp1 - p_entry) / risk end;
  ok := r1 >= 0.8;
  reasons := reasons || jsonb_build_object('rule','tp1_distance','ok',coalesce(ok,false),'detail',
     format('TP1 = %sR (min 0.8R)', round(r1, 2))); all_ok := all_ok and coalesce(ok,false);

  if p_note is not null and length(p_note) > 0 then
    reasons := reasons || jsonb_build_object('rule','analyst_note','ok',true,'detail',p_note);
  end if;

  insert into suggestions (source, created_by, symbol, side, order_type, entry, stop_loss, tp1, tp2, expires_at,
                           check_passed, check_reasons, hist_win_rate, hist_avg_r, hist_sample, risk_usd_001)
  values ('analyst', auth.uid(), p_symbol, p_side, p_order_type, p_entry, p_stop, p_tp1, p_tp2,
          now() + make_interval(hours => p_valid_hours), all_ok, reasons,
          case when all_ok then (hist->>'win_rate')::numeric end, case when all_ok then (hist->>'avg_r')::numeric end,
          case when all_ok then (hist->>'sample')::int end, round(risk, 1))
  returning id into new_id;
  return new_id;
end $$;
revoke all on function public.analyst_submit_signal(text,text,text,numeric,numeric,numeric,numeric,integer,text) from public, anon;
grant execute on function public.analyst_submit_signal(text,text,text,numeric,numeric,numeric,numeric,integer,text) to authenticated;

-- ---------- Telegram notifications ----------
-- Set once (SQL editor):
--   insert into app_secrets values ('telegram_bot_token','<from BotFather>'), ('telegram_chat_id','<channel id, e.g. -100...>');
create extension if not exists pg_net;

create or replace function public.telegram_send(p_text text) returns void
language plpgsql security definer set search_path = public as $$
declare tok text := (select value from app_secrets where name = 'telegram_bot_token');
        chat text := (select value from app_secrets where name = 'telegram_chat_id');
begin
  if tok is null or chat is null then return; end if;
  perform net.http_post(
    url := 'https://api.telegram.org/bot' || tok || '/sendMessage',
    body := jsonb_build_object('chat_id', chat, 'text', p_text, 'disable_web_page_preview', true),
    headers := '{"Content-Type":"application/json"}'::jsonb);
end $$;
revoke all on function public.telegram_send(text) from public, anon, authenticated;

create or replace function public.signal_notify() returns trigger
language plpgsql security definer set search_path = public as $$
declare name text := case when new.symbol = 'XAUUSD' then 'الذهب' else new.symbol end;
        dir text := case when new.side = 'BUY' then 'شراء' else 'بيع' end;
        msg text;
begin
  if tg_op = 'INSERT' then
    msg := format(E'توصية جديدة · %s %s\nالدخول: %s\nوقف الخسارة: %s\nالهدف 1: %s\nالهدف 2: %s\nالمخاطرة: %s$ لكل 0.01 لوت\nالتفاصيل وحجم اللوت المناسب لحسابك في غرفة التداول',
                  dir, name, new.entry, new.stop_loss, new.tp1, coalesce(new.tp2::text, '—'), new.risk_usd_001);
  elsif new.state is distinct from old.state then
    msg := case new.state
      when 'open'    then format('%s %s · اتفعّلت الصفقة على %s', name, dir, new.entry)
      when 'tp1'     then format('%s %s · تحقق الهدف 1 ✅ انقل الستوب لنقطة الدخول', name, dir)
      when 'tp2'     then format('%s %s · تحقق الهدف 2 ✅✅', name, dir)
      when 'sl'      then format('%s %s · ضربت وقف الخسارة ❌', name, dir)
      when 'be'      then format('%s %s · رجعت لنقطة الدخول بعد الهدف 1 (ربح على نص الصفقة)', name, dir)
      when 'expired' then format('%s %s · الأمر المعلق ما اتفعّل وانلغى', name, dir)
      when 'closed'  then format('%s %s · أُغلقت بعد 5 أيام', name, dir)
      else null end;
  end if;
  if msg is not null then perform telegram_send(msg); end if;
  return new;
end $$;

drop trigger if exists signals_notify on public.signals;
create trigger signals_notify after insert or update of state on public.signals
  for each row execute function public.signal_notify();
