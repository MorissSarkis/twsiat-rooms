-- 004: the engine inside the database.
--  * ingest_prices(): the MT5 bridge posts M5 bars here (protected by a token)
--  * engine_make_suggestion(): once a day, the rules-based suggestion for the back office
--  * engine_track(): every 5 minutes, updates each published signal from the prices
--  * engine_tick(): what the scheduler calls
-- Rules = engine/rules.py (Phase 1, gold): daily trend SMA50 + H1 EMA50/200 at creation,
-- limit entry at daily pivot P, stop 0.7 x ATR14(daily), TP1 1R, TP2 3R, expiry 20:00 GMT,
-- max hold 5 days. Times = broker server time (Exness = GMT) stored as timestamptz UTC.

-- ---------- config & secrets (no API access) ----------
create table if not exists public.app_secrets (name text primary key, value text not null);
revoke all on public.app_secrets from anon, authenticated;

create table if not exists public.app_config (key text primary key, value jsonb not null);
revoke all on public.app_config from anon, authenticated;
insert into public.app_config values
  ('rules', '{"sma_days":50,"atr_days":14,"ema_fast":50,"ema_slow":200,"sl_atr":0.7,"tp1_r":1,"tp2_r":3,"expiry_hour":20,"max_hold_days":5}'),
  ('hist_XAUUSD', '{"win_rate":52.7,"avg_r":0.096,"sample":641}')
on conflict (key) do nothing;

create table if not exists public.engine_log (
  id bigserial primary key, t timestamptz not null default now(), symbol text, msg text, data jsonb);
grant select on public.engine_log to authenticated;
alter table public.engine_log enable row level security;
create policy "staff read log" on public.engine_log for select using (public.my_role() in ('analyst','manager','admin'));

alter table public.signals add column if not exists last_bar_t timestamptz;
alter table public.signals drop constraint if exists signals_state_check;
alter table public.signals add constraint signals_state_check
  check (state in ('waiting','open','tp1','tp2','sl','be','expired','closed'));

-- ---------- price bridge ----------
-- p_bars: [{"t":"2026.10.14 06:25","o":..,"h":..,"l":..,"c":..,"s":spread_in_price}]
create or replace function public.ingest_prices(p_token text, p_symbol text, p_bars jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if p_token is null or p_token <> (select value from app_secrets where name = 'bridge_token') then
    raise exception 'bad token';
  end if;
  insert into prices_m5 (symbol, t, open, high, low, close, spread)
  select p_symbol, to_timestamp(b->>'t', 'YYYY.MM.DD HH24:MI') at time zone 'UTC',
         (b->>'o')::numeric, (b->>'h')::numeric, (b->>'l')::numeric, (b->>'c')::numeric, (b->>'s')::numeric
  from jsonb_array_elements(p_bars) b
  on conflict (symbol, t) do update
    set open = excluded.open, high = excluded.high, low = excluded.low, close = excluded.close, spread = excluded.spread;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.ingest_prices(text, text, jsonb) from public;
grant execute on function public.ingest_prices(text, text, jsonb) to anon, authenticated;

-- ---------- indicators ----------
-- Market context for a trading day, from daily bars strictly before that day.
create or replace function public.engine_context(p_symbol text, p_day date)
returns table (n_days integer, prev_close numeric, sma numeric, atr numeric, p numeric, r1 numeric, s1 numeric)
language sql stable set search_path = public as $$
  with d as (
    select (t at time zone 'UTC')::date as day,
           (array_agg(open order by t))[1] as o, max(high) as h, min(low) as l,
           (array_agg(close order by t desc))[1] as c
    from prices_m5
    where symbol = p_symbol and t < (p_day::timestamp at time zone 'UTC')
      and t >= ((p_day - 120)::timestamp at time zone 'UTC')
    group by 1
  ), w as (
    select day, h, l, c,
           greatest(h - l, abs(h - lag(c) over o), abs(l - lag(c) over o)) as tr,
           row_number() over (order by day desc) as rn,
           count(*) over () as n
    from d window o as (order by day)
  ), last as (select * from w where rn = 1)
  select (select n from last)::int,
         (select c from last),
         (select avg(c) from w where rn <= 50),
         (select avg(tr) from w where rn <= 14),
         (select (h + l + c) / 3 from last),
         (select 2 * (h + l + c) / 3 - l from last),
         (select 2 * (h + l + c) / 3 - h from last);
$$;

-- H1 trend (EMA50 > EMA200, pandas ewm adjust=True) using H1 bars strictly before the hour of p_t.
create or replace function public.engine_h1_up(p_symbol text, p_t timestamptz)
returns boolean language sql stable set search_path = public as $$
  with h as (
    select date_trunc('hour', t) as hr, (array_agg(close order by t desc))[1] as c
    from prices_m5
    where symbol = p_symbol and t < date_trunc('hour', p_t) and t >= p_t - interval '200 days'
    group by 1
  ), r as (select c, row_number() over (order by hr desc) - 1 as k from h)
  select (sum(c * power(1 - 2.0/51, k)) / sum(power(1 - 2.0/51, k)))
       > (sum(c * power(1 - 2.0/201, k)) / sum(power(1 - 2.0/201, k)))
  from r;
$$;

-- ---------- daily suggestion ----------
create or replace function public.engine_make_suggestion(p_symbol text default 'XAUUSD', p_now timestamptz default now())
returns bigint language plpgsql security definer set search_path = public as $$
declare
  cfg jsonb := (select value from app_config where key = 'rules');
  hist jsonb := (select value from app_config where key = 'hist_' || p_symbol);
  d date := (p_now at time zone 'UTC')::date;
  day_start timestamptz := d::timestamp at time zone 'UTC';
  first_t timestamptz; first_o numeric; ctx record; buy boolean; h1 boolean;
  e numeric; sld numeric; s int; new_id bigint;
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
  e := round(ctx.p, 2);
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
          e, round(ctx.p - s * sld, 2), round(ctx.p + s * (cfg->>'tp1_r')::numeric * sld, 2),
          round(ctx.p + s * (cfg->>'tp2_r')::numeric * sld, 2),
          day_start + make_interval(hours => (cfg->>'expiry_hour')::int),
          true,
          jsonb_build_array(
            jsonb_build_object('rule','daily_trend','ok',true,'detail', format('prev close %s %s SMA50 (%s)', round(ctx.prev_close,2), case when buy then 'above' else 'below' end, round(ctx.sma,2))),
            jsonb_build_object('rule','h1_trend','ok',true,'detail', format('H1 EMA50 %s EMA200', case when buy then 'above' else 'below' end)),
            jsonb_build_object('rule','entry_at_pivot','ok',true,'detail', format('P = %s', e)),
            jsonb_build_object('rule','stop_atr','ok',true,'detail', format('0.7 x ATR = %s', round(sld,2)))),
          (hist->>'win_rate')::numeric, (hist->>'avg_r')::numeric, (hist->>'sample')::int,
          round(sld, 1), p_now)
  returning id into new_id;
  insert into engine_log(t, symbol, msg, data) values (p_now, p_symbol, 'suggestion created', jsonb_build_object('id', new_id));
  return new_id;
end $$;

-- ---------- tracking ----------
-- Walks new M5 bars for every live signal. Conservative: SL before TP within a bar;
-- TP is not counted on the fill bar. Results for both client styles:
--   result_r_tp1only (all out at TP1)  and  result_r_partial (half at TP1, stop to entry, rest to TP2).
create or replace function public.engine_track(p_now timestamptz default now())
returns integer language plpgsql security definer set search_path = public as $$
declare
  sig record; b record; buy boolean; stop numeric; risk numeric; r1 numeric; r2 numeric;
  lo numeric; hi numeric; hold interval; n int := 0; done boolean;
begin
  hold := make_interval(days => ((select value from app_config where key = 'rules')->>'max_hold_days')::int);
  for sig in select * from signals where state in ('waiting','open','tp1') order by id loop
    buy := sig.side = 'BUY';
    risk := abs(sig.entry - sig.stop_loss);
    r1 := abs(sig.tp1 - sig.entry) / risk;
    r2 := case when sig.tp2 is null then null else abs(sig.tp2 - sig.entry) / risk end;
    stop := case when sig.state = 'tp1' then sig.entry else sig.stop_loss end;
    done := false;
    for b in select * from prices_m5
             where symbol = sig.symbol and t > coalesce(sig.last_bar_t, sig.published_at - interval '5 minutes')
               and t <= p_now
             order by t loop
      sig.last_bar_t := b.t;
      lo := case when buy then b.low else b.low + b.spread end;
      hi := case when buy then b.high else b.high + b.spread end;

      if sig.state = 'waiting' then
        if sig.expires_at is not null and b.t >= sig.expires_at then
          sig.state := 'expired'; sig.closed_at := b.t; done := true; exit;
        end if;
        if (buy and b.low + b.spread <= sig.entry) or ((not buy) and b.high >= sig.entry) then
          sig.state := 'open'; sig.filled_at := b.t;
        else
          continue;
        end if;
      end if;

      -- time exit
      if b.t > sig.filled_at + hold then
        if sig.state = 'tp1' then
          sig.result_r_partial := round(0.5 * r1 + 0.5 * ((case when buy then b.close - sig.entry else sig.entry - b.close end) / risk), 3);
        else
          sig.result_r_tp1only := round((case when buy then b.close - sig.entry else sig.entry - b.close end) / risk, 3);
          sig.result_r_partial := sig.result_r_tp1only;
        end if;
        sig.state := 'closed'; sig.closed_at := b.t; done := true; exit;
      end if;

      -- stop
      if (buy and lo <= stop) or ((not buy) and hi >= stop) then
        if sig.state = 'tp1' then
          sig.state := 'be'; sig.result_r_partial := round(0.5 * r1, 3);
        else
          sig.state := 'sl'; sig.result_r_tp1only := -1; sig.result_r_partial := -1;
        end if;
        sig.closed_at := b.t; done := true; exit;
      end if;

      if b.t > sig.filled_at then
        if sig.state = 'open' and ((buy and hi >= sig.tp1) or ((not buy) and lo <= sig.tp1)) then
          sig.state := 'tp1'; sig.tp1_at := b.t; sig.result_r_tp1only := round(r1, 3);
          stop := sig.entry; sig.stop_moved_to := sig.entry;
          if r2 is null then
            sig.result_r_partial := round(r1, 3); sig.state := 'tp2'; sig.closed_at := b.t; done := true; exit;
          end if;
        end if;
        if sig.state = 'tp1' and ((buy and hi >= sig.tp2) or ((not buy) and lo <= sig.tp2)) then
          sig.state := 'tp2'; sig.result_r_partial := round(0.5 * r1 + 0.5 * r2, 3);
          sig.closed_at := b.t; done := true; exit;
        end if;
      end if;
    end loop;

    update signals set state = sig.state, filled_at = sig.filled_at, tp1_at = sig.tp1_at, closed_at = sig.closed_at,
           result_r_tp1only = sig.result_r_tp1only, result_r_partial = sig.result_r_partial,
           stop_moved_to = sig.stop_moved_to, last_bar_t = sig.last_bar_t
     where id = sig.id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- pending suggestions that were never decided expire with their order
create or replace function public.engine_expire_suggestions(p_now timestamptz default now())
returns void language sql security definer set search_path = public as $$
  update suggestions set status = 'expired' where status = 'pending' and expires_at is not null and expires_at <= p_now;
$$;

create or replace function public.engine_tick()
returns void language plpgsql security definer set search_path = public as $$
begin
  perform engine_make_suggestion('XAUUSD');
  perform engine_track();
  perform engine_expire_suggestions();
end $$;

revoke all on function public.engine_make_suggestion(text, timestamptz) from public, anon, authenticated;
revoke all on function public.engine_track(timestamptz) from public, anon, authenticated;
revoke all on function public.engine_tick() from public, anon, authenticated;
revoke all on function public.engine_expire_suggestions(timestamptz) from public, anon, authenticated;
