-- 014: manual signals for any instrument. Risk per 0.01 lot in dollars (was price distance),
-- prices rounded to the instrument's decimals. Managers can publish directly from the form (web app).

create or replace function public.analyst_submit_signal(
  p_symbol text, p_side text, p_order_type text,
  p_entry numeric, p_stop numeric, p_tp1 numeric, p_tp2 numeric,
  p_valid_hours integer default 12, p_note text default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare
  hist jsonb := (select value from app_config where key = 'hist_' || p_symbol);
  usd numeric := coalesce(((select value from app_config where key = 'usd_per_point_001')->>p_symbol)::numeric, 1);
  d date := (now() at time zone 'UTC')::date;
  ctx record; buy boolean := p_side = 'BUY'; h1 boolean; risk numeric; ratio numeric; r1 numeric;
  reasons jsonb := '[]'; ok boolean; all_ok boolean := true; new_id bigint; e numeric := p_entry; last record;
begin
  if coalesce(my_role(), 'client') not in ('analyst','manager','admin') then raise exception 'not allowed'; end if;
  if p_side not in ('BUY','SELL') then raise exception 'bad side'; end if;
  if p_order_type = 'MARKET' then
    select * into last from prices_m5 where symbol = p_symbol order by t desc limit 1;
    if last.t is not null then e := case when buy then last.close + coalesce(last.spread,0) else last.close end; end if;
  end if;
  if e is null then raise exception 'حط سعر الدخول'; end if;

  select * into ctx from engine_context(p_symbol, d);
  h1 := engine_h1_up(p_symbol, now());
  risk := abs(e - p_stop);

  ok := case when buy then p_stop < e and e < p_tp1 else p_tp1 < e and e < p_stop end;
  reasons := reasons || jsonb_build_object('rule','levels_order','ok',ok,'detail','SL / entry / TP on the correct sides'); all_ok := all_ok and ok;
  ok := ctx.sma is not null and (ctx.prev_close > ctx.sma) = buy;
  reasons := reasons || jsonb_build_object('rule','daily_trend','ok',coalesce(ok,false),'detail',
     format('daily trend is %s', case when ctx.sma is null then 'unknown' when ctx.prev_close > ctx.sma then 'UP' else 'DOWN' end)); all_ok := all_ok and coalesce(ok,false);
  ok := h1 is not null and h1 = buy;
  reasons := reasons || jsonb_build_object('rule','h1_trend','ok',ok,'detail',
     format('H1 trend is %s', case when h1 is null then 'unknown' when h1 then 'UP' else 'DOWN' end)); all_ok := all_ok and ok;
  ratio := case when ctx.atr > 0 then risk / ctx.atr end;
  ok := ratio between 0.25 and 1.2;
  reasons := reasons || jsonb_build_object('rule','stop_size','ok',coalesce(ok,false),'detail',
     format('stop = %s x daily ATR (allowed 0.25–1.2)', round(ratio, 2))); all_ok := all_ok and coalesce(ok,false);
  r1 := case when risk > 0 then abs(p_tp1 - e) / risk end;
  ok := r1 >= 0.8;
  reasons := reasons || jsonb_build_object('rule','tp1_distance','ok',coalesce(ok,false),'detail',
     format('TP1 = %sR (min 0.8R)', round(r1, 2))); all_ok := all_ok and coalesce(ok,false);
  if p_note is not null and length(p_note) > 0 then
    reasons := reasons || jsonb_build_object('rule','analyst_note','ok',true,'detail',p_note);
  end if;

  insert into suggestions (source, created_by, symbol, side, order_type, entry, stop_loss, tp1, tp2, expires_at,
                           check_passed, check_reasons, hist_win_rate, hist_avg_r, hist_sample, risk_usd_001)
  values ('analyst', auth.uid(), p_symbol, p_side, p_order_type, e, p_stop, p_tp1, p_tp2,
          now() + make_interval(hours => coalesce(p_valid_hours, 12)), all_ok, reasons,
          case when all_ok then (hist->>'win_rate')::numeric end, case when all_ok then (hist->>'avg_r')::numeric end,
          case when all_ok then (hist->>'sample')::int end, round(risk * usd, 2))
  returning id into new_id;
  return new_id;
end $$;
revoke all on function public.analyst_submit_signal(text,text,text,numeric,numeric,numeric,numeric,integer,text) from public, anon;
grant execute on function public.analyst_submit_signal(text,text,text,numeric,numeric,numeric,numeric,integer,text) to authenticated;
