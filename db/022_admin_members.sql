-- 022: members list for the back office (rooms.twsiat.com/admin/members)
-- Email, sign-up and last login live in auth.users (Supabase Auth); this joins them with profiles
-- for managers/admins only. Nothing else is opened up. Safe to run more than once.

create or replace function public.admin_members(p_search text default null, p_status text default null,
                                                p_limit int default 100, p_offset int default 0)
returns table (
  id uuid, name text, username text, email text, provider text, role text,
  signed_up timestamptz, last_login timestamptz, email_confirmed boolean,
  ib_verified boolean, broker text, broker_account text, balance_usd numeric, room smallint,
  activation_requested_at timestamptz, verified_at timestamptz,
  alerts_paid_until timestamptz, alerts_reason text, total bigint)
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
           p.activation_requested_at, p.verified_at, p.alerts_paid_until,
           alerts_access_of(p.id)->>'reason' as alerts_reason
    from profiles p join auth.users u on u.id = p.id
    where (q is null or u.email ilike '%' || q || '%' or p.display_name ilike '%' || q || '%'
           or p.username ilike '%' || q || '%' or p.broker_account = q)
  ), f as (
    select * from m
    where p_status is null or p_status = ''
       or (p_status = 'ib' and m.ib_verified)
       or (p_status = 'pending' and not m.ib_verified and m.activation_requested_at is not null)
       or (p_status = 'paid' and m.alerts_reason = 'paid')
       or (p_status = 'none' and not m.ib_verified and m.activation_requested_at is null and m.alerts_reason in ('none','expired'))
       or (p_status = 'staff' and m.role in ('analyst','manager','admin'))
  )
  select f.*, count(*) over () as total from f
  order by f.signed_up desc
  limit least(greatest(p_limit, 1), 5000) offset greatest(p_offset, 0);
end $$;
revoke all on function public.admin_members(text, text, int, int) from public;
grant execute on function public.admin_members(text, text, int, int) to authenticated;

-- emails for the activation / payment queues in the back office
create or replace function public.admin_emails(p_ids uuid[]) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if coalesce(my_role(), '') not in ('manager','admin') then raise exception 'not allowed'; end if;
  return coalesce((select jsonb_object_agg(id, email) from auth.users where id = any(p_ids)), '{}'::jsonb);
end $$;
revoke all on function public.admin_emails(uuid[]) from public;
grant execute on function public.admin_emails(uuid[]) to authenticated;
