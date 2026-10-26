-- 024: simpler sign-up for the pivot alerts
--  * every new member gets the alerts free for 48 hours, right away (existing members get 48 hours from now)
--  * one activation form: broker + account number + "is it under our agency?" + WhatsApp number
--    (the number is required when the account is NOT under our agency, so the team can call and help move it)
--  * staff can approve or reject a request with a reason the member sees on the site
-- Safe to run more than once.

alter table public.profiles add column if not exists phone text;                       -- WhatsApp, international (+971...)
alter table public.profiles add column if not exists has_ib_account boolean;           -- member's answer: under our agency?
alter table public.profiles add column if not exists alerts_trial_until timestamptz;
alter table public.profiles add column if not exists activation_rejected_at timestamptz;
alter table public.profiles add column if not exists activation_note text;             -- reason shown to the member

alter table public.profiles alter column alerts_trial_until set default (now() + interval '48 hours');
update public.profiles set alerts_trial_until = now() + interval '48 hours' where alerts_trial_until is null;

-- staff-only fields (the sign-up functions below set them through a flag)
create or replace function public.protect_profile_fields() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- auth.uid() is null for dashboard / service-key changes; twsiat.sys is set by our own functions below
  if auth.uid() is not null and coalesce(current_setting('twsiat.sys', true), '') <> '1'
     and coalesce(public.my_role(), 'client') not in ('manager','admin') then
    if new.role is distinct from old.role
       or new.ib_verified is distinct from old.ib_verified
       or new.room is distinct from old.room
       or new.balance_usd is distinct from old.balance_usd
       or new.verified_at is distinct from old.verified_at
       or new.verified_by is distinct from old.verified_by
       or new.alerts_paid_until is distinct from old.alerts_paid_until
       or new.alerts_trial_until is distinct from old.alerts_trial_until
       or new.activation_rejected_at is distinct from old.activation_rejected_at
       or new.activation_note is distinct from old.activation_note then
      raise exception 'not allowed';
    end if;
  end if;
  return new;
end $$;

-- access rule: staff > agency client > paid > 48-hour trial
create or replace function public.alerts_access_of(p_uid uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select case
    when p.id is null then jsonb_build_object('ok', false, 'reason', 'none')
    when p.role in ('analyst','manager','admin') then jsonb_build_object('ok', true, 'reason', 'staff', 'role', p.role)
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

-- member sends the activation form
create or replace function public.submit_activation(p_broker text, p_account text, p_has_ib boolean, p_phone text)
returns void language plpgsql security definer set search_path = public as $$
declare ph text := regexp_replace(coalesce(p_phone, ''), '[\s\-\(\)\.]', '', 'g'); acc text := btrim(coalesce(p_account, ''));
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if ph like '00%' then ph := '+' || substr(ph, 3); end if;
  if ph <> '' and ph !~ '^\+[1-9][0-9]{7,14}$' then raise exception 'bad phone'; end if;
  if p_has_ib is not true and ph = '' then raise exception 'phone required'; end if;
  if p_has_ib is true and acc !~ '^[0-9]{4,15}$' then raise exception 'bad account'; end if;
  if acc <> '' and acc !~ '^[0-9]{4,15}$' then raise exception 'bad account'; end if;
  perform set_config('twsiat.sys', '1', true);
  update profiles set broker = nullif(btrim(coalesce(p_broker, '')), ''), broker_account = nullif(acc, ''),
         has_ib_account = coalesce(p_has_ib, false), phone = coalesce(nullif(ph, ''), phone),
         activation_requested_at = now(), activation_rejected_at = null, activation_note = null
  where id = auth.uid();
end $$;
revoke all on function public.submit_activation(text, text, boolean, text) from public;
grant execute on function public.submit_activation(text, text, boolean, text) to authenticated;

-- staff: reject / close a request with a reason the member sees
create or replace function public.admin_reject_activation(p_user uuid, p_note text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(my_role(), '') not in ('manager','admin') then raise exception 'not allowed'; end if;
  update profiles set activation_rejected_at = now(), activation_note = left(nullif(btrim(coalesce(p_note, '')), ''), 300)
  where id = p_user;
end $$;
revoke all on function public.admin_reject_activation(uuid, text) from public;
grant execute on function public.admin_reject_activation(uuid, text) to authenticated;

-- members list: + phone, agency answer, trial, rejection
drop function if exists public.admin_members(text, text, int, int);
create or replace function public.admin_members(p_search text default null, p_status text default null,
                                                p_limit int default 100, p_offset int default 0)
returns table (
  id uuid, name text, username text, email text, provider text, role text,
  signed_up timestamptz, last_login timestamptz, email_confirmed boolean,
  ib_verified boolean, broker text, broker_account text, balance_usd numeric, room smallint,
  activation_requested_at timestamptz, verified_at timestamptz, verified_by_name text,
  alerts_paid_until timestamptz, alerts_reason text,
  phone text, has_ib_account boolean, alerts_trial_until timestamptz, activation_rejected_at timestamptz, activation_note text,
  total bigint)
language plpgsql stable security definer set search_path = public as $$
declare q text := nullif(btrim(coalesce(p_search, '')), '');
begin
  if coalesce(my_role(), '') not in ('manager','admin') then raise exception 'not allowed'; end if;
  return query
  with m as (
    select p.id, p.display_name as name, p.username, u.email::text as email,
           coalesce(u.raw_app_meta_data->>'provider', 'email') as provider, p.role,
           u.created_at as signed_up, u.last_sign_in_at as last_login, (u.email_confirmed_at is not null) as email_confirmed,
           p.ib_verified, p.broker, p.broker_account, p.balance_usd, p.room,
           p.activation_requested_at, p.verified_at,
           (select coalesce(nullif(v.display_name, ''), v.username) from profiles v where v.id = p.verified_by) as verified_by_name,
           p.alerts_paid_until,
           alerts_access_of(p.id)->>'reason' as alerts_reason,
           p.phone, p.has_ib_account, p.alerts_trial_until, p.activation_rejected_at, p.activation_note
    from profiles p join auth.users u on u.id = p.id
    where (q is null or u.email ilike '%' || q || '%' or p.display_name ilike '%' || q || '%'
           or p.username ilike '%' || q || '%' or p.broker_account = q or p.phone like '%' || q || '%')
  ), f as (
    select * from m
    where p_status is null or p_status = ''
       or (p_status = 'ib' and m.ib_verified)
       or (p_status = 'pending' and not m.ib_verified and m.activation_requested_at is not null and m.activation_rejected_at is null)
       or (p_status = 'transfer' and not m.ib_verified and m.has_ib_account is false and m.activation_rejected_at is null)
       or (p_status = 'paid' and m.alerts_reason = 'paid')
       or (p_status = 'trial' and m.alerts_reason = 'trial')
       or (p_status = 'none' and not m.ib_verified and m.activation_requested_at is null and m.alerts_reason in ('none','expired','trial_over'))
       or (p_status = 'staff' and m.role in ('analyst','manager','admin'))
  )
  select f.*, count(*) over () as total from f
  order by f.signed_up desc
  limit least(greatest(p_limit, 1), 5000) offset greatest(p_offset, 0);
end $$;
revoke all on function public.admin_members(text, text, int, int) from public;
grant execute on function public.admin_members(text, text, int, int) to authenticated;
