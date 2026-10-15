-- 009: never publish a suggestion whose entry has already been reached or passed.
-- An engine suggestion is made at the day's open. If price touches the entry before the
-- manager approves, clients can no longer get that entry (a Sell Limit below the market
-- cannot be placed), so the suggestion is stale.

create or replace function public.suggestion_live_check(p_id bigint)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  s record; last record; hb numeric; la numeric; lb numeric; ha numeric; bid numeric; ask numeric; reason text;
begin
  if coalesce(my_role(), 'client') not in ('analyst','manager','admin') then raise exception 'not allowed'; end if;
  select * into s from suggestions where id = p_id;
  if s.id is null then return jsonb_build_object('ok', false, 'reason', 'not found'); end if;
  select * into last from prices_m5 where symbol = s.symbol order by t desc limit 1;
  if last.t is null then return jsonb_build_object('ok', true, 'reason', null); end if;
  bid := last.close; ask := last.close + coalesce(last.spread, 0);
  -- extremes since the suggestion was made: bid high/low and ask high/low
  select max(high), min(low + coalesce(spread,0)), min(low), max(high + coalesce(spread,0)) into hb, la, lb, ha
    from prices_m5 where symbol = s.symbol and t >= s.created_at - interval '5 minutes';

  if s.expires_at is not null and s.expires_at <= now() then
    reason := 'انتهت صلاحية الأمر';
  elsif s.order_type = 'SELL_LIMIT' and (bid >= s.entry or hb >= s.entry) then
    reason := format('السعر وصل الدخول %s قبل الموافقة (أعلى سعر %s، الآن %s) — الفرصة فاتت', s.entry, coalesce(round(hb, 2)::text, '—'), round(bid, 2));
  elsif s.order_type = 'BUY_LIMIT' and (ask <= s.entry or la <= s.entry) then
    reason := format('السعر وصل الدخول %s قبل الموافقة (أدنى سعر %s، الآن %s) — الفرصة فاتت', s.entry, coalesce(round(la, 2)::text, '—'), round(ask, 2));
  elsif s.order_type = 'SELL_STOP' and (bid <= s.entry or lb <= s.entry) then
    reason := format('السعر كسر الدخول %s قبل الموافقة (الآن %s)', s.entry, round(bid, 2));
  elsif s.order_type = 'BUY_STOP' and (ask >= s.entry or ha >= s.entry) then
    reason := format('السعر كسر الدخول %s قبل الموافقة (الآن %s)', s.entry, round(ask, 2));
  elsif s.order_type = 'MARKET' and abs((case when s.side = 'BUY' then ask else bid end) - s.entry) > 0.25 * abs(s.entry - s.stop_loss) then
    reason := format('السعر ابتعد عن الدخول %s (الآن %s)', s.entry, round(bid, 2));
  end if;
  return jsonb_build_object('ok', reason is null, 'reason', reason, 'price', bid, 'price_t', last.t);
end $$;
revoke all on function public.suggestion_live_check(bigint) from public, anon;
grant execute on function public.suggestion_live_check(bigint) to authenticated;

-- Pending suggestions whose chance has passed are closed automatically every 5 minutes.
create or replace function public.engine_expire_suggestions(p_now timestamptz default now())
returns void language plpgsql security definer set search_path = public as $$
declare s record; hb numeric; la numeric; lb numeric; ha numeric;
begin
  update suggestions set status = 'expired' where status = 'pending' and expires_at is not null and expires_at <= p_now;
  for s in select * from suggestions where status = 'pending' and order_type <> 'MARKET' loop
    select max(high), min(low + coalesce(spread,0)), min(low), max(high + coalesce(spread,0)) into hb, la, lb, ha
      from prices_m5 where symbol = s.symbol and t >= s.created_at - interval '5 minutes' and t <= p_now;
    if (s.order_type = 'SELL_LIMIT' and hb >= s.entry) or (s.order_type = 'BUY_LIMIT' and la <= s.entry)
    or (s.order_type = 'SELL_STOP'  and lb <= s.entry) or (s.order_type = 'BUY_STOP'  and ha >= s.entry) then
      update suggestions set status = 'expired', decision_note = 'تلقائي: السعر وصل الدخول قبل الموافقة' where id = s.id;
    end if;
  end loop;
end $$;
revoke all on function public.engine_expire_suggestions(timestamptz) from public, anon, authenticated;
