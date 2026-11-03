-- 035: engine v2 — intraday gold suggestions (H1), waiting for an account manager's approval.
-- Run once in the Supabase SQL Editor. Nothing is published to clients without approval.
--
-- Rules (= engine/rules2.py, tested on Exness M5 2020-01 … 2026-11, spread included):
--   * trend: previous D1 close vs EMA50(D1) AND previous H4 close vs EMA50(H4) agree
--   * levels: classic daily pivots, trading day = New York close (21:00 / 22:00 GMT with US DST)
--   * trigger: the closed H1 bar touches P / S1 / S2 (buy) or P / R1 / R2 (sell) within 0.15 x ATR(H1, 14)
--     and closes back on the trend side, at most 0.6 x ATR away from the level
--   * stop: entry -/+ 2.5 x ATR(H1);  TP1 = 1.8R;  TP2 = first pivot level beyond TP1 (else TP1 + 1R)
--   * hours: tested 12:00–20:00 server time (GMT). Signals at other hours are still created but
--     marked "outside tested hours" (check_passed = false) — the manager decides.
--   * max 2 tested-hours suggestions per trading day; none while a passed v2 suggestion or a v2 signal is still live
--   * order type MARKET, valid 2 hours (publishing is refused if price moved > 0.25R: suggestion_live_check)
-- Backtest with the existing tracking (half at TP1, stop to entry, rest to TP2, 5-day hold):
--   433 trades, avg +0.131R (2020-23 +0.152R, 2024-26 +0.098R), max DD 17.5R.
--   With 30-minute approval delay: avg +0.175R. With 60 minutes: +0.095R → approve fast.

-- ---------- source + config ----------
alter table public.suggestions drop constraint if exists suggestions_source_check;
alter table public.suggestions add constraint suggestions_source_check
  check (source in ('engine','engine2','analyst','community'));

insert into public.app_config (key, value) values
  ('engine2', '{"trend_ema":50,"atr_h1":14,"tol_atr":0.15,"max_entry_atr":0.6,"sl_atr":2.5,"tp1_r":1.8,
                "sess_start":12,"sess_end":20,"friday_last_hour":18,"max_per_day":2,"valid_hours":2,
                "ny_close_winter":22,"ny_close_summer":21,"max_bar_age_min":20,"outside_hours":true}'),
  ('engine2_symbols', '["XAUUSD"]'),
  ('hist_XAUUSD_v2', '{"win_rate":42.3,"avg_r":0.131,"sample":433}')
on conflict (key) do nothing;

-- ---------- helpers ----------
-- Start of the New-York-close trading day that contains p_t (US daylight saving rules).
create or replace function public.engine2_ny_start(p_t timestamptz, p_winter int, p_summer int)
returns timestamptz language plpgsql immutable as $$
declare
  u timestamp := p_t at time zone 'UTC';
  y int := extract(year from u)::int;
  m1 date := make_date(y, 3, 1); m2 date := make_date(y, 11, 1);
  s timestamp;
begin
  m1 := m1 + ((7 - extract(dow from m1)::int) % 7) + 7;   -- 2nd Sunday of March
  m2 := m2 + ((7 - extract(dow from m2)::int) % 7);       -- 1st Sunday of November
  s := u::date + make_interval(hours => case when u >= m1 and u < m2 then p_summer else p_winter end);
  if s > u then s := s - interval '1 day'; end if;
  return s at time zone 'UTC';
end $$;

-- Hourly bars built from the M5 bars (UTC hours, hours without data are skipped).
create or replace function public.engine2_h1(p_symbol text, p_from timestamptz, p_to timestamptz)
returns table (hr timestamptz, o numeric, h numeric, l numeric, c numeric, sp numeric)
language sql stable set search_path = public as $$
  select date_trunc('hour', t at time zone 'UTC') at time zone 'UTC' as hr,
         (array_agg(open order by t))[1], max(high), min(low),
         (array_agg(close order by t desc))[1], (array_agg(spread order by t desc))[1]
  from prices_m5
  where symbol = p_symbol and t >= p_from and t < p_to
  group by 1 order by 1;
$$;

-- EMA (pandas ewm adjust=False) of the last closes of closed buckets before p_t.
-- p_kind = 'D1' (UTC days, Sundays skipped) or 'H4' (UTC 4-hour buckets). Returns (close, ema) of the last bucket.
create or replace function public.engine2_trend_leg(p_symbol text, p_t timestamptz, p_kind text, p_n int,
                                                    out last_close numeric, out ema numeric)
language plpgsql stable set search_path = public as $$
declare k numeric := 2.0 / (p_n + 1); r record; cnt int := 0;
begin
  for r in
    with b as (
      select case when p_kind = 'D1'
                  then date_trunc('day', t at time zone 'UTC')
                  else date_trunc('day', t at time zone 'UTC')
                       + make_interval(hours => (extract(hour from t at time zone 'UTC')::int / 4) * 4) end as bk,
             t, close
      from prices_m5
      where symbol = p_symbol
        and t >= p_t - case when p_kind = 'D1' then interval '420 days' else interval '80 days' end
        and t < p_t
    ), g as (
      select bk, (array_agg(close order by t desc))[1] as c
      from b group by bk
    )
    select bk, c from g
    where (p_kind = 'D1' and extract(dow from bk) <> 0 and bk + interval '1 day' <= p_t at time zone 'UTC')
       or (p_kind = 'H4' and bk + interval '4 hours' <= p_t at time zone 'UTC')
    order by bk
  loop
    ema := case when cnt = 0 then r.c else k * r.c + (1 - k) * ema end;
    last_close := r.c;
    cnt := cnt + 1;
  end loop;
  if cnt < p_n then last_close := null; ema := null; end if;
end $$;

-- ---------- the scan (called every 5 minutes by engine_tick) ----------
create or replace function public.engine2_scan(p_symbol text default 'XAUUSD', p_now timestamptz default now())
returns bigint language plpgsql security definer set search_path = public as $$
declare
  cfg jsonb := (select value from app_config where key = 'engine2');
  hist jsonb := (select value from app_config where key = 'hist_' || p_symbol || '_v2');
  usd numeric := coalesce(((select value from app_config where key = 'usd_per_point_001')->>p_symbol)::numeric, 1);
  last_t timestamptz; hs timestamptz; t timestamptz; ds timestamptz; w_end timestamptz;
  bars record; bar record; atr numeric; tol numeric; lv numeric[]; nm text[] := array['S3','S2','S1','P','R1','R2','R3'];
  ph numeric; pl numeric; pc numeric; pp numeric; rg numeric; nh int;
  d1 record; h4 record; dir int; idx int; i int; k int;
  entry numeric; risk numeric; sl numeric; tp1 numeric; tp2 numeric;
  tested boolean; ok boolean; all_ok boolean := true; reasons jsonb := '[]'; n_today int; new_id bigint;
  opp text; uh int; udow int; staff uuid[];
begin
  -- last closed H1 bar: complete when its 55-minute M5 bar has arrived
  select max(p.t) into last_t from prices_m5 p where p.symbol = p_symbol and p.t <= p_now;
  if last_t is null then return null; end if;
  hs := date_trunc('hour', (last_t - interval '55 minutes') at time zone 'UTC') at time zone 'UTC';
  t := hs + interval '1 hour';                                   -- signal time = bar close
  if exists (select 1 from engine_log where symbol = p_symbol and msg = 'v2 scanned' and data->>'bar' = hs::text) then
    return null;
  end if;
  insert into engine_log(t, symbol, msg, data) values (p_now, p_symbol, 'v2 scanned', jsonb_build_object('bar', hs::text));
  if p_now - t > make_interval(mins => (cfg->>'max_bar_age_min')::int) then return null; end if;   -- prices late: skip

  uh := extract(hour from t at time zone 'UTC')::int;
  udow := extract(dow from t at time zone 'UTC')::int;
  if udow = 5 and uh >= (cfg->>'friday_last_hour')::int then return null; end if;   -- no new trades late Friday
  if udow in (0, 6) and uh < 22 then return null; end if;
  tested := uh >= (cfg->>'sess_start')::int and uh < (cfg->>'sess_end')::int;
  if not tested and not coalesce((cfg->>'outside_hours')::boolean, true) then return null; end if;

  -- the bar and ATR(14) from the last 15 hourly bars
  select * into bar from engine2_h1(p_symbol, hs, hs + interval '1 hour');
  if bar.hr is null then return null; end if;
  select avg(tr) into atr from (
    select greatest(h - l, abs(h - lag(c) over (order by hr)), abs(l - lag(c) over (order by hr))) as tr, hr
    from (select * from engine2_h1(p_symbol, hs - interval '10 days', hs + interval '1 hour') order by hr desc limit 15) x
    order by hr desc limit 14) y;
  if atr is null or atr <= 0 then return null; end if;
  tol := (cfg->>'tol_atr')::numeric * atr;

  -- trend
  select * into d1 from engine2_trend_leg(p_symbol, t, 'D1', (cfg->>'trend_ema')::int);
  select * into h4 from engine2_trend_leg(p_symbol, t, 'H4', (cfg->>'trend_ema')::int);
  if d1.ema is null or h4.ema is null then return null; end if;
  dir := case when d1.last_close > d1.ema and h4.last_close > h4.ema then 1
              when d1.last_close < d1.ema and h4.last_close < h4.ema then -1 else 0 end;
  if dir = 0 then return null; end if;

  -- pivots of the previous NY-close day (skip weekend gaps)
  ds := engine2_ny_start(t, (cfg->>'ny_close_winter')::int, (cfg->>'ny_close_summer')::int);
  w_end := ds;
  for i in 1..4 loop
    select max(h), min(l), (array_agg(c order by hr desc))[1], count(*) into ph, pl, pc, nh
      from engine2_h1(p_symbol, w_end - interval '1 day', w_end);
    exit when nh >= 3;
    w_end := w_end - interval '1 day';
  end loop;
  if nh is null or nh < 3 then return null; end if;
  pp := (ph + pl + pc) / 3; rg := ph - pl;
  lv := array[pl - 2 * (ph - pp), pp - rg, 2 * pp - ph, pp, 2 * pp - pl, pp + rg, ph + 2 * (pp - pl)];

  -- trigger (arrays are 1-based: 2=S2 3=S1 4=P 5=R1 6=R2)
  idx := null;
  if dir = 1 then
    foreach i in array array[2,3,4] loop
      if bar.l <= lv[i] + tol and bar.c > lv[i] and bar.c - lv[i] <= (cfg->>'max_entry_atr')::numeric * atr then idx := i; exit; end if;
    end loop;
  else
    foreach i in array array[6,5,4] loop
      if bar.h >= lv[i] - tol and bar.c < lv[i] and lv[i] - bar.c <= (cfg->>'max_entry_atr')::numeric * atr then idx := i; exit; end if;
    end loop;
  end if;
  if idx is null then return null; end if;

  -- limits: one live v2 trade at a time, max N tested-hours suggestions per trading day
  if exists (select 1 from suggestions where source = 'engine2' and symbol = p_symbol and status = 'pending' and check_passed)
     or exists (select 1 from signals g join suggestions s on s.id = g.suggestion_id
                where s.source = 'engine2' and g.symbol = p_symbol and g.state in ('waiting','open','tp1')) then
    insert into engine_log(t, symbol, msg, data) values (p_now, p_symbol, 'v2 skipped: previous v2 still live', jsonb_build_object('bar', hs::text));
    return null;
  end if;
  select count(*) into n_today from suggestions s
   where s.source = 'engine2' and s.symbol = p_symbol
     and s.expires_at - make_interval(hours => (cfg->>'valid_hours')::int) >= ds
     and (s.status = 'approved'
          or extract(hour from (s.expires_at - make_interval(hours => (cfg->>'valid_hours')::int)) at time zone 'UTC')::int
             between (cfg->>'sess_start')::int and (cfg->>'sess_end')::int - 1);
  if n_today >= (cfg->>'max_per_day')::int then
    insert into engine_log(t, symbol, msg, data) values (p_now, p_symbol, 'v2 skipped: daily limit', jsonb_build_object('bar', hs::text));
    return null;
  end if;

  -- levels of the trade
  entry := round(bar.c + case when dir = 1 then coalesce(bar.sp, 0) else 0 end, 2);
  risk := (cfg->>'sl_atr')::numeric * atr;
  sl := round(entry - dir * risk, 2);
  tp1 := round(entry + dir * (cfg->>'tp1_r')::numeric * risk, 2);
  tp2 := null; k := idx + dir;
  while k between 1 and 7 loop
    if (lv[k] - tp1) * dir > 0 then tp2 := round(lv[k], 2); exit; end if;
    k := k + dir;
  end loop;
  tp2 := coalesce(tp2, round(tp1 + dir * risk, 2));

  -- checks shown to the manager
  reasons := reasons || jsonb_build_object('rule','engine','ok',true,'detail',
    format('محرك v2 (لحظي H1): لمس %s ورفض، الاتجاه %s', nm[idx], case when dir = 1 then 'صاعد' else 'هابط' end));
  reasons := reasons || jsonb_build_object('rule','trend','ok',true,'detail',
    format('D1 close %s EMA50 %s · H4 close %s EMA50 %s', round(d1.last_close,2), round(d1.ema,2), round(h4.last_close,2), round(h4.ema,2)));
  reasons := reasons || jsonb_build_object('rule','stop_atr','ok',true,'detail',
    format('stop = 2.5 x ATR(H1) = %s · TP1 = 1.8R · TP2 = %s', round(risk,2), tp2));
  reasons := reasons || jsonb_build_object('rule','hours','ok',tested,'detail',
    case when tested then format('✅ ضمن الساعات المختبرة (%s:00 GMT)', uh)
         else format('⚠️ خارج الساعات المختبرة (%s:00 GMT) — نتائجها التاريخية أضعف بكثير', uh) end);
  all_ok := all_ok and tested;
  select string_agg(format('#%s %s', x.id, x.side), ', ') into opp from (
    select s.id, s.side from suggestions s where s.symbol = p_symbol and s.status = 'pending'
       and s.side <> case when dir = 1 then 'BUY' else 'SELL' end
    union all
    select g.id, g.side from signals g where g.symbol = p_symbol and not g.shadow and g.state in ('waiting','open','tp1')
       and g.side <> case when dir = 1 then 'BUY' else 'SELL' end) x;
  ok := opp is null;
  reasons := reasons || jsonb_build_object('rule','conflict','ok',ok,'detail',
    case when ok then 'لا يوجد تعارض مع توصيات الذهب الأخرى' else '⚠️ تعارض مع توصية بالاتجاه المعاكس: ' || opp end);
  all_ok := all_ok and ok;

  insert into suggestions (source, symbol, side, order_type, entry, stop_loss, tp1, tp2, expires_at,
                           check_passed, check_reasons, hist_win_rate, hist_avg_r, hist_sample, risk_usd_001, created_at)
  values ('engine2', p_symbol, case when dir = 1 then 'BUY' else 'SELL' end, 'MARKET', entry, sl, tp1, tp2,
          t + make_interval(hours => (cfg->>'valid_hours')::int), all_ok, reasons,
          (hist->>'win_rate')::numeric, (hist->>'avg_r')::numeric, (hist->>'sample')::int,
          round(risk * usd, 1), p_now)
  returning id into new_id;
  insert into engine_log(t, symbol, msg, data) values (p_now, p_symbol, 'v2 suggestion created', jsonb_build_object('id', new_id, 'bar', hs::text));

  -- tell the managers right away (approval within ~30 minutes keeps the edge)
  select array_agg(id) into staff from profiles where role in ('manager','admin');
  if staff is not null then
    begin
      perform push_send(staff,
        format('🟡 توصية ذهب جديدة (v2) · %s %s', case when dir = 1 then 'شراء' else 'بيع' end, case when all_ok then '✅' else '⚠️' end),
        format('الدخول %s · الستوب %s · الهدف 1 %s · وافق خلال 30 دقيقة', entry, sl, tp1),
        '/admin', 'sug' || new_id);
    exception when others then
      insert into engine_log(t, symbol, msg, data) values (p_now, p_symbol, 'v2 push failed', jsonb_build_object('err', sqlerrm));
    end;
  end if;
  return new_id;
end $$;
revoke all on function public.engine2_scan(text, timestamptz) from public, anon, authenticated;

-- ---------- engine_tick: same as 012 + engine v2 ----------
create or replace function public.engine_tick()
returns void language plpgsql security definer set search_path = public as $$
declare sym text; sh jsonb;
begin
  for sym in select jsonb_array_elements_text(value) from app_config where key = 'engine_symbols' loop
    perform engine_make_suggestion(sym);
  end loop;
  for sym in select jsonb_array_elements_text(value) from app_config where key = 'engine2_symbols' loop
    begin
      perform engine2_scan(sym);
    exception when others then      -- v2 must never stop the rest of the engine
      insert into engine_log(t, symbol, msg, data) values (now(), sym, 'v2 error', jsonb_build_object('err', sqlerrm));
    end;
  end loop;
  for sh in select jsonb_array_elements(value) from app_config where key = 'shadow_rules' loop
    perform engine_shadow(sh->>'symbol', sh->>'ref', (sh->>'ref_sign')::int);
  end loop;
  perform engine_track();
  perform community_track();
  perform engine_expire_suggestions();
end $$;
revoke all on function public.engine_tick() from public, anon, authenticated;

-- To pause v2 without touching code:   update app_config set value = '[]' where key = 'engine2_symbols';
-- Only tested hours (no ⚠️ suggestions): update app_config set value = jsonb_set(value, '{outside_hours}', 'false') where key = 'engine2';
