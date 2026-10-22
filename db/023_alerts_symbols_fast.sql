-- 023: alerts_symbols was scanning ten days of M5 bars for every symbol (hundreds of thousands of rows)
-- and hit the 3-second API timeout as history grew. Same answer, now by jumping through the
-- primary key (symbol, t) one symbol at a time: a few dozen index lookups instead of a big scan.
-- Safe to run more than once.

create or replace function public.alerts_symbols(p_token text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare cfg jsonb := (select value from app_config where key = 'symbols');
begin
  perform alerts_check(p_token);
  return coalesce((
    with recursive syms as (
      (select symbol from prices_m5 order by symbol limit 1)
      union all
      select (select p.symbol from prices_m5 p where p.symbol > s.symbol order by p.symbol limit 1)
      from syms s where s.symbol is not null
    ), recent as (
      select symbol from syms s
      where s.symbol is not null
        and exists (select 1 from prices_m5 p where p.symbol = s.symbol and p.t > now() - interval '10 days')
      union
      select symbol from prices_live where t > now() - interval '10 days'
    )
    select jsonb_object_agg(r.symbol,
             (select (x->>'digits')::int from jsonb_array_elements(coalesce(cfg, '[]'::jsonb)) x
              where x->>'code' = r.symbol limit 1))
    from recent r), '{}'::jsonb);
end $$;
revoke all on function public.alerts_symbols(text) from public;
grant execute on function public.alerts_symbols(text) to anon, authenticated;
