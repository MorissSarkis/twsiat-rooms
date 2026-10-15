-- 008: Phase 3 — community room (room 3) and the levels page.
--  * Clients post trade ideas through community_post() only. The server checks the levels,
--    stamps the market price itself (MARKET orders) and nobody can edit or delete a post.
--  * community_track() follows every idea on the same M5 prices as the expert signals.
--  * community_feed() / community_leaderboard() show usernames (profiles stay private).
--  * market_levels() feeds the levels page: pivots, previous-day range, Fibonacci, trend.

-- ---------- symbols available on the platform (must also be in the MT5 bridge SymbolMap) ----------
insert into public.app_config values
  ('symbols', '[{"code":"XAUUSD","name":"الذهب","digits":2}]'),
  ('community', '{"max_open":5,"max_per_day":10,"pending_hours":24,"max_hold_days":5,"min_sl_atr":0.1,"max_sl_atr":3,"rank_after":20}')
on conflict (key) do nothing;

create or replace function public.list_symbols() returns jsonb
language sql stable security definer set search_path = public as
$$ select value from app_config where key = 'symbols' $$;
revoke all on function public.list_symbols() from public, anon;
grant execute on function public.list_symbols() to authenticated;

-- ---------- usernames ----------
alter table public.profiles drop constraint if exists profiles_username_format;
alter table public.profiles add constraint profiles_username_format
  check (username is null or username ~ '^[A-Za-z0-9_]{3,20}$');
create unique index if not exists profiles_username_lower on public.profiles (lower(username));

-- ---------- community trades: extra columns, posting only through the function ----------
alter table public.community_trades add column if not exists posted_price numeric;
alter table public.community_trades add column if not exists last_bar_t timestamptz;
alter table public.community_trades add column if not exists note text;
drop policy if exists "community post" on public.community_trades;
revoke insert, update, delete on public.community_trades from anon, authenticated;
grant select on public.community_trades to authenticated;

create or replace function public.community_post(
  p_symbol text, p_side text, p_order_type text,
  p_entry numeric, p_stop numeric, p_tp numeric, p_note text default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare
  cfg jsonb := (select value from app_config where key = 'community');
  me record; last record; ctx record; buy boolean := p_side = 'BUY';
  bid numeric; ask numeric; e numeric; risk numeric; new_id bigint;
begin
  select * into me from profiles where id = auth.uid();
  if me.id is null or not me.ib_verified then raise exception 'حسابك لازم يكون مفعّل لتنشر بالغرفة'; end if;
  if me.username is null then raise exception 'اختار اسم مستخدم أول'; end if;
  if p_side not in ('BUY','SELL') then raise exception 'اتجاه غير صحيح'; end if;
  if p_order_type not in ('MARKET','BUY_LIMIT','SELL_LIMIT','BUY_STOP','SELL_STOP')
     or (p_order_type <> 'MARKET' and split_part(p_order_type, '_', 1) <> p_side) then
    raise exception 'نوع الأمر لا يطابق الاتجاه';
  end if;
  if not exists (select 1 from jsonb_array_elements(list_symbols()) s where s->>'code' = p_symbol) then
    raise exception 'الأصل غير متاح';
  end if;
  if (select count(*) from community_trades where user_id = me.id and state in ('waiting','open')) >= (cfg->>'max_open')::int then
    raise exception 'عندك % أفكار مفتوحة، استنى لتسكّر وحدة', cfg->>'max_open';
  end if;
  if (select count(*) from community_trades where user_id = me.id and posted_at > now() - interval '1 day') >= (cfg->>'max_per_day')::int then
    raise exception 'وصلت للحد اليومي (%)', cfg->>'max_per_day';
  end if;

  select * into last from prices_m5 where symbol = p_symbol order by t desc limit 1;
  if last.t is null then raise exception 'ما في أسعار لهالأصل'; end if;
  bid := last.close; ask := last.close + coalesce(last.spread, 0);

  if p_order_type = 'MARKET' then
    if last.t < now() - interval '15 minutes' then raise exception 'السوق مسكّر هلق، استعمل أمر معلق'; end if;
    e := case when buy then ask else bid end;       -- the server sets the price, not the client
  else
    e := p_entry;
    if e is null then raise exception 'حط سعر الدخول'; end if;
    if (p_order_type = 'BUY_LIMIT'  and e >= ask) or (p_order_type = 'BUY_STOP'  and e <= ask)
    or (p_order_type = 'SELL_LIMIT' and e <= bid) or (p_order_type = 'SELL_STOP' and e >= bid) then
      raise exception 'سعر الدخول ما بيناسب نوع الأمر (السعر الحالي %)', round(bid, 2);
    end if;
  end if;

  if buy and not (p_stop < e and e < p_tp) then raise exception 'للشراء: الستوب تحت الدخول والهدف فوقه'; end if;
  if (not buy) and not (p_tp < e and e < p_stop) then raise exception 'للبيع: الهدف تحت الدخول والستوب فوقه'; end if;

  risk := abs(e - p_stop);
  select * into ctx from engine_context(p_symbol, (now() at time zone 'UTC')::date);
  if ctx.atr is not null and (risk < (cfg->>'min_sl_atr')::numeric * ctx.atr or risk > (cfg->>'max_sl_atr')::numeric * ctx.atr) then
    raise exception 'مسافة الستوب غير منطقية لهالأصل (المدى اليومي تقريباً %)', round(ctx.atr, 1);
  end if;

  insert into community_trades (user_id, symbol, side, order_type, entry, stop_loss, take_profit,
                                posted_at, expires_at, state, filled_at, posted_price, last_bar_t, note)
  values (me.id, p_symbol, p_side, p_order_type, e, p_stop, p_tp, now(),
          case when p_order_type = 'MARKET' then null else now() + make_interval(hours => (cfg->>'pending_hours')::int) end,
          case when p_order_type = 'MARKET' then 'open' else 'waiting' end,
          case when p_order_type = 'MARKET' then last.t end,   -- entry = close of this bar; later bars count fully
          bid, last.t, nullif(left(trim(p_note), 280), ''))
  returning id into new_id;
  return new_id;
end $$;
revoke all on function public.community_post(text,text,text,numeric,numeric,numeric,text) from public, anon;
grant execute on function public.community_post(text,text,text,numeric,numeric,numeric,text) to authenticated;

-- ---------- tracking (same conservative rules as the expert signals) ----------
create or replace function public.community_track(p_now timestamptz default now())
returns integer language plpgsql security definer set search_path = public as $$
declare
  c record; b record; buy boolean; risk numeric; lo numeric; hi numeric; n int := 0;
  hold interval := make_interval(days => ((select value from app_config where key = 'community')->>'max_hold_days')::int);
begin
  for c in select * from community_trades where state in ('waiting','open') order by id loop
    buy := c.side = 'BUY';
    risk := abs(c.entry - c.stop_loss);
    for b in select * from prices_m5
             where symbol = c.symbol and t > coalesce(c.last_bar_t, c.posted_at - interval '5 minutes') and t <= p_now
             order by t loop
      c.last_bar_t := b.t;
      lo := case when buy then b.low else b.low + b.spread end;
      hi := case when buy then b.high else b.high + b.spread end;

      if c.state = 'waiting' then
        if c.expires_at is not null and b.t >= c.expires_at then
          c.state := 'expired'; c.closed_at := b.t; exit;
        end if;
        if (c.order_type like '%LIMIT' and ((buy and b.low + b.spread <= c.entry) or ((not buy) and b.high >= c.entry)))
        or (c.order_type like '%STOP'  and ((buy and b.high + b.spread >= c.entry) or ((not buy) and b.low <= c.entry))) then
          c.state := 'open'; c.filled_at := b.t;
        else
          continue;
        end if;
      end if;

      if b.t > c.filled_at + hold then
        c.result_r := round((case when buy then b.close - c.entry else c.entry - b.close end) / risk, 3);
        c.state := 'closed'; c.closed_at := b.t; exit;
      end if;
      if (buy and lo <= c.stop_loss) or ((not buy) and hi >= c.stop_loss) then
        c.state := 'sl'; c.result_r := -1; c.closed_at := b.t; exit;
      end if;
      if b.t > c.filled_at and ((buy and hi >= c.take_profit) or ((not buy) and lo <= c.take_profit)) then
        c.state := 'tp'; c.result_r := round(abs(c.take_profit - c.entry) / risk, 3); c.closed_at := b.t; exit;
      end if;
    end loop;

    update community_trades set state = c.state, filled_at = c.filled_at, closed_at = c.closed_at,
           result_r = c.result_r, last_bar_t = c.last_bar_t
     where id = c.id;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.community_track(timestamptz) from public, anon, authenticated;

create or replace function public.engine_tick()
returns void language plpgsql security definer set search_path = public as $$
begin
  perform engine_make_suggestion('XAUUSD');
  perform engine_track();
  perform community_track();
  perform engine_expire_suggestions();
end $$;
revoke all on function public.engine_tick() from public, anon, authenticated;

-- ---------- reading the room ----------
create or replace function public.community_stats()
returns table (username text, trades int, wins int, win_rate numeric, total_r numeric, avg_r numeric, open_now int)
language sql stable security definer set search_path = public as $$
  select p.username,
         count(*) filter (where c.result_r is not null)::int,
         count(*) filter (where c.result_r > 0)::int,
         round(100.0 * count(*) filter (where c.result_r > 0) / nullif(count(*) filter (where c.result_r is not null), 0), 1),
         round(coalesce(sum(c.result_r), 0), 2),
         round(avg(c.result_r), 3),
         count(*) filter (where c.state in ('waiting','open'))::int
  from community_trades c join profiles p on p.id = c.user_id
  where auth.uid() is not null and p.username is not null
  group by p.username;
$$;
revoke all on function public.community_stats() from public, anon;
grant execute on function public.community_stats() to authenticated;

create or replace function public.community_feed(p_limit int default 50, p_username text default null)
returns table (id bigint, username text, mine boolean, symbol text, side text, order_type text, entry numeric,
               stop_loss numeric, take_profit numeric, posted_at timestamptz, expires_at timestamptz, state text,
               filled_at timestamptz, closed_at timestamptz, result_r numeric, note text)
language sql stable security definer set search_path = public as $$
  select c.id, p.username, c.user_id = auth.uid(), c.symbol, c.side, c.order_type, c.entry, c.stop_loss,
         c.take_profit, c.posted_at, c.expires_at, c.state, c.filled_at, c.closed_at, c.result_r, c.note
  from community_trades c join profiles p on p.id = c.user_id
  where auth.uid() is not null and (p_username is null or lower(p.username) = lower(p_username))
  order by c.posted_at desc
  limit least(greatest(p_limit, 1), 200);
$$;
revoke all on function public.community_feed(int, text) from public, anon;
grant execute on function public.community_feed(int, text) to authenticated;

-- ---------- levels page ----------
create or replace function public.market_levels(p_symbol text default 'XAUUSD')
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  last record; d date; ctx record; ph numeric; pl numeric; pc numeric; rng numeric; h1 boolean; up boolean;
begin
  if auth.uid() is null then return null; end if;
  select * into last from prices_m5 where symbol = p_symbol order by t desc limit 1;
  if last.t is null then return null; end if;
  d := (last.t at time zone 'UTC')::date;
  select * into ctx from engine_context(p_symbol, d);
  -- previous trading day's range
  select max(high), min(low), (array_agg(close order by t desc))[1] into ph, pl, pc
  from prices_m5 where symbol = p_symbol
    and (t at time zone 'UTC')::date = (select max((t at time zone 'UTC')::date) from prices_m5
                                        where symbol = p_symbol and t < (d::timestamp at time zone 'UTC'));
  rng := ph - pl;
  h1 := engine_h1_up(p_symbol, last.t + interval '1 hour');
  up := ctx.prev_close > ctx.sma;
  return jsonb_build_object(
    'symbol', p_symbol, 'day', d, 'price', last.close, 'price_t', last.t,
    'pivot', jsonb_build_object('R3', ph + 2 * (ctx.p - pl), 'R2', ctx.p + rng, 'R1', ctx.r1, 'P', ctx.p,
                                'S1', ctx.s1, 'S2', ctx.p - rng, 'S3', pl - 2 * (ph - ctx.p)),
    'prev', jsonb_build_object('high', ph, 'low', pl, 'close', pc),
    -- retracements of yesterday's range, measured in the direction of the daily trend
    'fib', jsonb_build_object(
      '23.6', case when up then ph - 0.236 * rng else pl + 0.236 * rng end,
      '38.2', case when up then ph - 0.382 * rng else pl + 0.382 * rng end,
      '50.0', case when up then ph - 0.5   * rng else pl + 0.5   * rng end,
      '61.8', case when up then ph - 0.618 * rng else pl + 0.618 * rng end,
      '78.6', case when up then ph - 0.786 * rng else pl + 0.786 * rng end),
    'atr', ctx.atr, 'sma50', ctx.sma,
    'daily_trend', case when ctx.sma is null then null when up then 'UP' else 'DOWN' end,
    'h1_trend', case when h1 is null then null when h1 then 'UP' else 'DOWN' end);
end $$;
revoke all on function public.market_levels(text) from public, anon;
grant execute on function public.market_levels(text) to authenticated;
