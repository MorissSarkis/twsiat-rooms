-- 030: the free alerts trial is 14 days (was 48 hours). After it ends the member needs an account under our agency
-- (staff activate it with a balance, which also opens the rooms), a paid subscription, or a free extension
-- from staff (admin_extend_trial below). Rooms are unchanged.
-- Requires 024. Safe to run more than once (it never shortens a trial).
alter table public.profiles alter column alerts_trial_until set default (now() + interval '14 days');

update public.profiles
set alerts_trial_until = now() + interval '14 days'
where not ib_verified
  and coalesce(role, 'client') = 'client'
  and (alerts_trial_until is null or alerts_trial_until < now() + interval '14 days')
  and not exists (select 1 from public.app_config where key = 'trial_14_given');

insert into public.app_config (key, value) values ('trial_14_given', to_jsonb(now())) on conflict (key) do nothing;

-- staff: extend a member's free alerts by any number of days (from today, or from the trial end if it is later).
-- 0 days ends the free period now.
create or replace function public.admin_extend_trial(p_user uuid, p_days int) returns timestamptz
language plpgsql security definer set search_path = public as $$
declare until timestamptz;
begin
  if coalesce(my_role(), '') not in ('manager','admin') then raise exception 'not allowed'; end if;
  if p_days is null or p_days < 0 or p_days > 3660 then raise exception 'bad days'; end if;
  update profiles set alerts_trial_until = case when p_days = 0 then now()
           else greatest(now(), coalesce(alerts_trial_until, now())) + make_interval(days => p_days) end
  where id = p_user returning alerts_trial_until into until;
  return until;
end $$;
revoke all on function public.admin_extend_trial(uuid, int) from public;
grant execute on function public.admin_extend_trial(uuid, int) to authenticated;
