-- 020: pivot alerts app (alerts.twsiat.com)
--  * prices_live     : latest bid per symbol, pushed by the MT5 bridge every few seconds (bridge v2.1)
--  * ingest_live()   : the bridge writes live quotes here (same bridge_token as ingest_prices)
--  * alerts_symbols(): which symbols have prices, with their decimals
--  * alerts_feed()   : live quote + last closed M5 bar for a list of symbols
--  * alerts_daily()  : daily bars (UTC day = Exness server day) for pivots, ATR, daily change and trend
-- The alerts server reads with its own token (app_secrets 'alerts_token'); nothing else is opened up.
-- Existing tables, the engine and the levels page are not changed.

-- ---------- live quotes ----------
create table if not exists public.prices_live (
  symbol text primary key,
  bid    numeric not null,
  t      timestamptz not null
);
alter table public.prices_live enable row level security;
drop policy if exists "live read" on public.prices_live;
create policy "live read" on public.prices_live for select using (auth.uid() is not null);
grant select on public.prices_live to authenticated;

-- p_quotes: [{"s":"XAUUSD","b":4127.03,"t":"2026.10.21 17:41:05"}]  (t = broker time converted to GMT)
create or replace function public.ingest_live(p_token text, p_quotes jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if p_token is null or p_token <> (select value from app_secrets where name = 'bridge_token') then
    raise exception 'bad token';
  end if;
  insert into prices_live (symbol, bid, t)
  select q->>'s', (q->>'b')::numeric, replace(q->>'t', '.', '-')::timestamp at time zone 'UTC'
  from jsonb_array_elements(p_quotes) q
  where (q->>'b')::numeric > 0
  on conflict (symbol) do update set bid = excluded.bid, t = excluded.t
    where excluded.t >= prices_live.t;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.ingest_live(text, jsonb) from public;
grant execute on function public.ingest_live(text, jsonb) to anon, authenticated;

-- ---------- reading for the alerts server ----------
insert into public.app_secrets (name, value)
values ('alerts_token', replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''))
on conflict (name) do nothing;

create or replace function public.alerts_check(p_token text) returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if p_token is null or p_token <> (select value from app_secrets where name = 'alerts_token') then
    raise exception 'bad token';
  end if;
end $$;
revoke all on function public.alerts_check(text) from public, anon, authenticated;

-- symbols with prices in the last 10 days -> {"XAUUSD": 2, "EURGBP": null, ...} (decimals from app_config when known)
create or replace function public.alerts_symbols(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare cfg jsonb := (select value from app_config where key = 'symbols');
begin
  perform alerts_check(p_token);
  return coalesce((
    select jsonb_object_agg(s.symbol,
             (select (x->>'digits')::int from jsonb_array_elements(coalesce(cfg, '[]'::jsonb)) x
              where x->>'code' = s.symbol limit 1))
    from (select distinct symbol from prices_m5 where t > now() - interval '10 days'
          union select symbol from prices_live where t > now() - interval '10 days') s), '{}'::jsonb);
end $$;

-- {"now": ..., "live": {"XAUUSD": [bid, t]}, "m5": {"XAUUSD": [close, t]}}
create or replace function public.alerts_feed(p_token text, p_symbols text[])
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform alerts_check(p_token);
  return jsonb_build_object(
    'now', now(),
    'live', coalesce((select jsonb_object_agg(symbol, jsonb_build_array(bid, t))
                      from prices_live where symbol = any(p_symbols)), '{}'::jsonb),
    'm5', coalesce((select jsonb_object_agg(s, jsonb_build_array(b.close, b.t))
                    from unnest(p_symbols) s
                    cross join lateral (select close, t from prices_m5 where symbol = s order by t desc limit 1) b),
                   '{}'::jsonb));
end $$;

-- daily bars for one symbol, oldest first: [["2026-10-20", o, h, l, c], ...] (today's unfinished day included last)
create or replace function public.alerts_daily(p_token text, p_symbol text, p_days int default 400)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform alerts_check(p_token);
  return coalesce((
    select jsonb_agg(jsonb_build_array(day, o, h, l, c) order by day)
    from (
      select (t at time zone 'UTC')::date as day,
             (array_agg(open order by t))[1] as o, max(high) as h, min(low) as l,
             (array_agg(close order by t desc))[1] as c
      from prices_m5
      where symbol = p_symbol
        and t >= ((now() at time zone 'UTC')::date - least(greatest(p_days, 20), 450))::timestamp at time zone 'UTC'
      group by 1
    ) d), '[]'::jsonb);
end $$;

revoke all on function public.alerts_symbols(text) from public;
revoke all on function public.alerts_feed(text, text[]) from public;
revoke all on function public.alerts_daily(text, text, int) from public;
grant execute on function public.alerts_symbols(text) to anon, authenticated;
grant execute on function public.alerts_feed(text, text[]) to anon, authenticated;
grant execute on function public.alerts_daily(text, text, int) to anon, authenticated;

-- copy this value into the server's deploy/.env as ALERTS_TOKEN (never share it, never commit it)
select value as alerts_token from public.app_secrets where name = 'alerts_token';
