-- 011: Bitcoin joins the signal engine.
-- Backtest (Jan 2020 – Oct 2026, Exness M5, spread included, same rules as gold, no re-tuning):
--   BTCUSD 793 trades (~117/yr), 52.2% win, +0.070R/trade (half at TP1), 2020–23 +0.063, 2024–26 +0.079, max DD 21.7R.
-- Also tested and NOT added (edge too small or unstable): XAGUSD, USOIL, EURUSD, USDJPY, AUDUSD, USDCAD.

insert into public.app_config values
  ('engine_symbols', '["XAUUSD","BTCUSD"]'),
  ('usd_per_point_001', '{"XAUUSD":1,"BTCUSD":0.01}'),     -- $ per 1.0 price move for 0.01 lot (Exness: 1 lot = 100 oz / 1 BTC)
  ('hist_BTCUSD', '{"win_rate":52.2,"avg_r":0.070,"sample":793}')
on conflict (key) do update set value = excluded.value;

create or replace function public.engine_make_suggestion(p_symbol text default 'XAUUSD', p_now timestamptz default now())
returns bigint language plpgsql security definer set search_path = public as $$
declare
  cfg jsonb := (select value from app_config where key = 'rules');
  hist jsonb := (select value from app_config where key = 'hist_' || p_symbol);
  d date := (p_now at time zone 'UTC')::date;
  day_start timestamptz := d::timestamp at time zone 'UTC';
  first_t timestamptz; first_o numeric; ctx record; buy boolean; h1 boolean;
  e numeric; sld numeric; s int; new_id bigint;
  dg int := coalesce((select (x->>'digits')::int from jsonb_array_elements((select value from app_config where key = 'symbols')) x where x->>'code' = p_symbol), 2);
  usd numeric := coalesce(((select value from app_config where key = 'usd_per_point_001')->>p_symbol)::numeric, 1);
begin
  if exists (select 1 from suggestions where source = 'engine' and symbol = p_symbol
             and created_at >= day_start and created_at < day_start + interval '1 day') then
    return null;
  end if;
  if exists (select 1 from engine_log where symbol = p_symbol and msg like 'no setup%'
             and t >= day_start and t < day_start + interval '1 day') then
    return null;
  end if;
  select t, open into first_t, first_o from prices_m5
   where symbol = p_symbol and t >= day_start and t < day_start + interval '1 day' and t <= p_now
   order by t limit 1;
  if first_t is null then return null; end if;   -- market not open yet today

  select * into ctx from engine_context(p_symbol, d);
  if ctx.n_days is null or ctx.n_days < (cfg->>'sma_days')::int or ctx.atr is null then
    insert into engine_log(t, symbol, msg, data) values (p_now, p_symbol, 'no setup: not enough history', to_jsonb(ctx));
    return null;
  end if;
  buy := ctx.prev_close > ctx.sma;
  e := round(ctx.p, dg);
  if (buy and first_o <= ctx.p) or ((not buy) and first_o >= ctx.p) then
    insert into engine_log(t, symbol, msg, data) values (p_now, p_symbol, 'no setup: day opened beyond the pivot',
      jsonb_build_object('open', first_o, 'pivot', ctx.p, 'side', case when buy then 'BUY' else 'SELL' end));
    return null;
  end if;
  h1 := engine_h1_up(p_symbol, first_t);
  if h1 is distinct from buy then
    insert into engine_log(t, symbol, msg, data) values (p_now, p_symbol, 'no setup: H1 trend disagrees',
      jsonb_build_object('daily', case when buy then 'UP' else 'DOWN' end, 'h1_up', h1));
    return null;
  end if;

  sld := (cfg->>'sl_atr')::numeric * ctx.atr;
  s := case when buy then 1 else -1 end;
  insert into suggestions (source, symbol, side, order_type, entry, stop_loss, tp1, tp2, expires_at,
                           check_passed, check_reasons, hist_win_rate, hist_avg_r, hist_sample, risk_usd_001, created_at)
  values ('engine', p_symbol, case when buy then 'BUY' else 'SELL' end, case when buy then 'BUY_LIMIT' else 'SELL_LIMIT' end,
          e, round(ctx.p - s * sld, dg), round(ctx.p + s * (cfg->>'tp1_r')::numeric * sld, dg),
          round(ctx.p + s * (cfg->>'tp2_r')::numeric * sld, dg),
          day_start + make_interval(hours => (cfg->>'expiry_hour')::int),
          true,
          jsonb_build_array(
            jsonb_build_object('rule','daily_trend','ok',true,'detail', format('prev close %s %s SMA50 (%s)', round(ctx.prev_close, dg), case when buy then 'above' else 'below' end, round(ctx.sma, dg))),
            jsonb_build_object('rule','h1_trend','ok',true,'detail', format('H1 EMA50 %s EMA200', case when buy then 'above' else 'below' end)),
            jsonb_build_object('rule','entry_at_pivot','ok',true,'detail', format('P = %s', e)),
            jsonb_build_object('rule','stop_atr','ok',true,'detail', format('0.7 x ATR = %s', round(sld, dg)))),
          (hist->>'win_rate')::numeric, (hist->>'avg_r')::numeric, (hist->>'sample')::int,
          round(sld * usd, 2), p_now)
  returning id into new_id;
  insert into engine_log(t, symbol, msg, data) values (p_now, p_symbol, 'suggestion created', jsonb_build_object('id', new_id));
  return new_id;
end $$;

revoke all on function public.engine_make_suggestion(text, timestamptz) from public, anon, authenticated;

create or replace function public.engine_tick()
returns void language plpgsql security definer set search_path = public as $$
declare sym text;
begin
  for sym in select jsonb_array_elements_text(value) from app_config where key = 'engine_symbols' loop
    perform engine_make_suggestion(sym);
  end loop;
  perform engine_track();
  perform community_track();
  perform engine_expire_suggestions();
end $$;
revoke all on function public.engine_tick() from public, anon, authenticated;

-- Telegram: instrument names from the symbols list
create or replace function public.signal_notify() returns trigger
language plpgsql security definer set search_path = public as $$
declare name text := coalesce((select x->>'name' from jsonb_array_elements((select value from app_config where key = 'symbols')) x where x->>'code' = new.symbol), new.symbol);
        dir  text := case when new.side = 'BUY' then 'شراء' else 'بيع' end;
        url  text := (select value #>> '{}' from app_config where key = 'site_url');
        msg  text;
begin
  if tg_op = 'INSERT' then
    msg := format(E'🔔 توصية جديدة على %s (%s)\nالدخول والستوب والأهداف وحجم اللوت المناسب لحسابك داخل غرفتك.', name, dir);
  elsif new.state is distinct from old.state then
    msg := case new.state
      when 'open'    then format('⚡ %s %s · اتفعّلت الصفقة', name, dir)
      when 'tp1'     then format('✅ %s %s · تحقق الهدف 1 — انقل الستوب لنقطة الدخول', name, dir)
      when 'tp2'     then format('✅✅ %s %s · تحقق الهدف 2', name, dir)
      when 'sl'      then format('❌ %s %s · ضربت وقف الخسارة', name, dir)
      when 'be'      then format('↩️ %s %s · رجعت لنقطة الدخول بعد الهدف 1 (ربح على نص الصفقة)', name, dir)
      when 'expired' then format('⏹ %s %s · الأمر المعلّق ما اتفعّل وانلغى', name, dir)
      when 'closed'  then format('⏹ %s %s · أُغلقت بعد 5 أيام', name, dir)
      else null end;
  end if;
  if msg is not null then
    if url is not null then msg := msg || E'\n' || url; end if;
    perform telegram_send(msg);
  end if;
  return new;
end $$;
