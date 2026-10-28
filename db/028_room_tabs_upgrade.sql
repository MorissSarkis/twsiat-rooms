-- 028: both rooms visible as tabs.
--  * staff (analyst / manager / admin) read both rooms
--  * a room-2 member (1,000$ and above) can also open room 1
--  * a room-1 member who opens room 2 sees a locked screen + "I topped up, upgrade me" request
--  * manager/admin move a member between rooms (with the new balance); the member gets a Telegram note if linked
-- Requires 001–027. Safe to run more than once.

alter table public.profiles add column if not exists upgrade_requested_at timestamptz;
alter table public.profiles add column if not exists upgrade_balance numeric;     -- balance the member says he has now

-- signals: a member reads his room and every lower room
drop policy if exists "room readers" on public.signals;
create policy "room readers" on public.signals for select using (
  public.my_role() in ('analyst','manager','admin')
  or exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.ib_verified
      and exists (select 1 from unnest(signals.rooms) r where r <= p.room)
      and exists (select 1 from public.consents c where c.user_id = p.id and c.room = p.room)
  )
);

-- what a locked room shows: how many signals were published there in the last 30 days (no levels)
create or replace function public.room_teaser(p_room int) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'last30', (select count(*) from signals where not shadow and p_room = any(rooms) and published_at > now() - interval '30 days'),
    'closed', (select count(*) from signals where not shadow and p_room = any(rooms) and state in ('tp2','sl','be','closed')),
    'wins',   (select count(*) from signals where not shadow and p_room = any(rooms) and state in ('tp2','sl','be','closed') and result_r_partial > 0))
  where auth.uid() is not null;
$$;
revoke all on function public.room_teaser(int) from public, anon;
grant execute on function public.room_teaser(int) to authenticated;

-- member: "I topped up my account, move me to the big room"
create or replace function public.request_room_upgrade(p_balance numeric) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if p_balance is null or p_balance < 1000 or p_balance > 10000000 then raise exception 'رصيد غير صالح'; end if;
  update profiles set upgrade_requested_at = now(), upgrade_balance = p_balance
  where id = auth.uid() and ib_verified and coalesce(room, 1) = 1;
end $$;
revoke all on function public.request_room_upgrade(numeric) from public, anon;
grant execute on function public.request_room_upgrade(numeric) to authenticated;

-- manager/admin: set a member's room and balance (also answers an upgrade request)
create or replace function public.admin_set_room(p_user uuid, p_room int, p_balance numeric) returns void
language plpgsql security definer set search_path = public as $$
declare chat bigint; old_room int; url text := coalesce((select value #>> '{}' from app_config where key = 'site_url'), '');
begin
  if coalesce(my_role(), '') not in ('manager','admin') then raise exception 'not allowed'; end if;
  if p_room not in (1, 2) then raise exception 'bad room'; end if;
  select telegram_chat_id, room into chat, old_room from profiles where id = p_user;
  update profiles set room = p_room, balance_usd = coalesce(p_balance, balance_usd),
         upgrade_requested_at = null, upgrade_balance = null
  where id = p_user and ib_verified;
  if chat is not null and old_room is distinct from p_room then
    perform telegram_dm(chat, case when p_room = 2
      then E'تم نقلك لغرفة الحسابات الكبيرة (1,000$ وأكثر) ✅\nادخل ووافق على شروط الغرفة:\n' || url || 'rooms'
      else E'تم نقلك لغرفة الحسابات الصغيرة (أقل من 1,000$).\n' || url || 'rooms' end);
  end if;
end $$;
revoke all on function public.admin_set_room(uuid, int, numeric) from public, anon;
grant execute on function public.admin_set_room(uuid, int, numeric) to authenticated;
