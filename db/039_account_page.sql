-- 039: "حسابي" page. A verified member reports a new balance after a deposit, with an optional note.
--  * room 1 + balance ≥ 1,000$ → it's a request to move to room 2 (same queue as before)
--  * room 2 (or room 1 below 1,000$) → a balance update the team confirms
-- Same admin queue ("طلبات الانتقال للغرفة الكبيرة / تحديث الرصيد"); the note shows there. Safe to run more than once.

alter table public.profiles add column if not exists upgrade_note text;

create or replace function public.report_balance(p_balance numeric, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if p_balance is null or p_balance <= 0 or p_balance > 10000000 then raise exception 'رصيد غير صالح'; end if;
  update profiles set upgrade_requested_at = now(), upgrade_balance = p_balance,
         upgrade_note = nullif(left(trim(coalesce(p_note, '')), 500), '')
   where id = auth.uid() and ib_verified;
  if not found then raise exception 'حسابك لسا مش مفعّل'; end if;
end $$;
revoke all on function public.report_balance(numeric, text) from public, anon;
grant execute on function public.report_balance(numeric, text) to authenticated;

create or replace function public.admin_set_room(p_user uuid, p_room int, p_balance numeric) returns void
language plpgsql security definer set search_path = public as $$
declare chat bigint; old_room int; url text := coalesce((select value #>> '{}' from app_config where key = 'site_url'), '');
begin
  if coalesce(my_role(), '') not in ('manager','admin') then raise exception 'not allowed'; end if;
  if p_room not in (1, 2) then raise exception 'bad room'; end if;
  select telegram_chat_id, room into chat, old_room from profiles where id = p_user;
  update profiles set room = p_room, balance_usd = coalesce(p_balance, balance_usd),
         upgrade_requested_at = null, upgrade_balance = null, upgrade_note = null
  where id = p_user and ib_verified;
  if chat is not null and old_room is distinct from p_room then
    perform telegram_dm(chat, case when p_room = 2
      then E'تم نقلك لغرفة الحسابات الكبيرة (1,000$ وأكثر) ✅\nادخل ووافق على شروط الغرفة:\n' || url || 'rooms'
      else E'تم نقلك لغرفة الحسابات الصغيرة (أقل من 1,000$).\n' || url || 'rooms' end);
  end if;
end $$;
