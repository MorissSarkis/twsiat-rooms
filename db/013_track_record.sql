-- 013: public track record. Anyone (even not signed in) can see every published signal once it is CLOSED,
-- with its real result. Open signals show only that they exist (no levels), so the rooms keep their value.
-- Shadow (paper) signals are never included.

create or replace function public.track_record(p_limit int default 100)
returns jsonb language sql stable security definer set search_path = public as $$
  with s as (
    select * from signals where not shadow
  ), closed as (
    select * from s where state in ('tp2','sl','be','closed')
  )
  select jsonb_build_object(
    'summary', (select coalesce(jsonb_agg(x order by x.symbol), '[]') from (
        select symbol,
               count(*) as trades,
               count(*) filter (where result_r_partial > 0) as wins,
               round(100.0 * count(*) filter (where result_r_partial > 0) / nullif(count(*), 0), 1) as win_rate,
               round(coalesce(sum(result_r_partial), 0), 2) as total_r_partial,
               round(coalesce(sum(result_r_tp1only), 0), 2) as total_r_tp1only,
               round(avg(result_r_partial), 3) as avg_r_partial,
               min(published_at) as since
        from closed group by symbol) x),
    'open_now', (select count(*) from s where state in ('waiting','open','tp1')),
    'not_triggered', (select count(*) from s where state = 'expired'),
    'trades', (select coalesce(jsonb_agg(t order by t.closed_at desc), '[]') from (
        select id, symbol, side, order_type, entry, stop_loss, tp1, tp2, state,
               published_at, filled_at, tp1_at, closed_at, result_r_tp1only, result_r_partial
        from closed order by closed_at desc limit least(greatest(p_limit, 1), 500)) t)
  );
$$;
revoke all on function public.track_record(int) from public;
grant execute on function public.track_record(int) to anon, authenticated;
