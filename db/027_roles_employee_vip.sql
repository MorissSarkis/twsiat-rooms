-- 027: two more roles, set from the members page by the admin
--  * employee : team member who gets the alerts and the rooms for free, but no back office and no signals
--  * vip      : free member by the owner's decision (friends, exceptions): alerts and rooms for free
-- Setting either role also opens the rooms (like an activated client, room 2 unless one is already set).
-- Requires 024 and 026. Safe to run more than once.

alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check
  check (role in ('client','vip','employee','analyst','manager','admin'));

create or replace function public.admin_set_role(p_user uuid, p_role text) returns text
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(my_role(), '') <> 'admin' then raise exception 'not allowed'; end if;
  if p_role not in ('client','vip','employee','analyst','manager','admin') then raise exception 'bad role'; end if;
  if p_user = auth.uid() then raise exception 'not your own role'; end if;
  update profiles set role = p_role where id = p_user;
  if p_role in ('vip','employee') then              -- free access to the rooms too
    update profiles set ib_verified = true, room = coalesce(room, 2),
           verified_at = coalesce(verified_at, now()), verified_by = coalesce(verified_by, auth.uid())
    where id = p_user and not ib_verified;
  end if;
  return p_role;
end $$;
revoke all on function public.admin_set_role(uuid, text) from public;
grant execute on function public.admin_set_role(uuid, text) to authenticated;

-- alerts: free for these roles, whatever their account status
create or replace function public.alerts_access_of(p_uid uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select case
    when p.id is null then jsonb_build_object('ok', false, 'reason', 'none')
    when p.role in ('analyst','manager','admin') then jsonb_build_object('ok', true, 'reason', 'staff', 'role', p.role)
    when p.role = 'employee' then jsonb_build_object('ok', true, 'reason', 'employee', 'role', p.role)
    when p.role = 'vip' then jsonb_build_object('ok', true, 'reason', 'vip', 'role', p.role)
    when p.ib_verified then jsonb_build_object('ok', true, 'reason', 'ib', 'role', p.role)
    when p.alerts_paid_until > now() then jsonb_build_object('ok', true, 'reason', 'paid', 'role', p.role, 'until', p.alerts_paid_until)
    when p.alerts_trial_until > now() then jsonb_build_object('ok', true, 'reason', 'trial', 'role', p.role, 'until', p.alerts_trial_until)
    else jsonb_build_object('ok', false, 'role', p.role,
           'reason', case when p.alerts_paid_until is not null then 'expired' else 'trial_over' end,
           'until', coalesce(p.alerts_paid_until, p.alerts_trial_until))
  end
  from (select 1) one left join profiles p on p.id = p_uid
$$;
revoke all on function public.alerts_access_of(uuid) from public, anon, authenticated;

-- alerts app sign-in: these roles don't need to give a phone number first
create or replace function public.alerts_issue_code() returns text
language plpgsql security definer set search_path = public as $$
declare c text := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
        p profiles;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  select * into p from profiles where id = auth.uid();
  if p.phone is null and coalesce(p.role, 'client') = 'client' then raise exception 'phone required'; end if;
  if not (alerts_access_of(auth.uid())->>'ok')::boolean then raise exception 'no access'; end if;
  delete from alerts_codes where expires_at < now() or user_id = auth.uid();
  insert into alerts_codes values (c, auth.uid(), now() + interval '2 minutes');
  return c;
end $$;
revoke all on function public.alerts_issue_code() from public;
grant execute on function public.alerts_issue_code() to authenticated;
