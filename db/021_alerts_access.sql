-- 021: who can use the pivot alerts app (alerts.twsiat.com)
--  * free  : clients verified under our IB tag (profiles.ib_verified) — existing and new
--  * paid  : anyone else, by crypto payment; staff check the TXID and approve -> profiles.alerts_paid_until
--  * staff : analyst / manager / admin
-- Login hand-off: rooms.twsiat.com/alerts issues a one-time code (2 minutes), the alerts server redeems it
-- with its own ALERTS_TOKEN. No passwords are shared between the two sites.
-- Safe to run more than once.

-- ---------- paid-until on the profile (staff-only field) ----------
alter table public.profiles add column if not exists alerts_paid_until timestamptz;

create or replace function public.protect_profile_fields() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- auth.uid() is null for dashboard / service-key changes: allowed
  if auth.uid() is not null and coalesce(public.my_role(), 'client') not in ('manager','admin') then
    if new.role is distinct from old.role
       or new.ib_verified is distinct from old.ib_verified
       or new.room is distinct from old.room
       or new.balance_usd is distinct from old.balance_usd
       or new.verified_at is distinct from old.verified_at
       or new.verified_by is distinct from old.verified_by
       or new.alerts_paid_until is distinct from old.alerts_paid_until then
      raise exception 'not allowed';
    end if;
  end if;
  return new;
end $$;

-- ---------- price and wallets (edit in Table Editor -> app_config -> alerts_plan) ----------
insert into public.app_config (key, value) values ('alerts_plan', jsonb_build_object(
  'price_usd', 20,
  'days', 30,
  'wallets', jsonb_build_array(jsonb_build_object('network', 'USDT (TRC20)', 'address', ''))
)) on conflict (key) do nothing;

create or replace function public.alerts_plan() returns jsonb
language sql stable security definer set search_path = public as
$$ select coalesce((select value from app_config where key = 'alerts_plan'), '{}'::jsonb) $$;
revoke all on function public.alerts_plan() from public;
grant execute on function public.alerts_plan() to authenticated;

-- ---------- crypto payments ----------
create table if not exists public.alerts_payments (
  id          bigserial primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  amount_usd  numeric not null,
  network     text not null,
  txid        text not null unique,
  days        int not null,
  status      text not null default 'pending' check (status in ('pending','approved','rejected')),
  note        text,
  created_at  timestamptz not null default now(),
  decided_by  uuid references auth.users(id),
  decided_at  timestamptz
);
create index if not exists alerts_payments_pending on public.alerts_payments (created_at) where status = 'pending';
alter table public.alerts_payments enable row level security;
drop policy if exists "own or staff read" on public.alerts_payments;
create policy "own or staff read" on public.alerts_payments for select
  using (user_id = auth.uid() or public.my_role() in ('manager','admin'));
grant select on public.alerts_payments to authenticated;
-- writes only through the functions below

-- ---------- access rule (one place) ----------
create or replace function public.alerts_access_of(p_uid uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select case
    when p.id is null then jsonb_build_object('ok', false, 'reason', 'none')
    when p.role in ('analyst','manager','admin') then jsonb_build_object('ok', true, 'reason', 'staff', 'role', p.role)
    when p.ib_verified then jsonb_build_object('ok', true, 'reason', 'ib', 'role', p.role)
    when p.alerts_paid_until > now() then jsonb_build_object('ok', true, 'reason', 'paid', 'role', p.role, 'until', p.alerts_paid_until)
    else jsonb_build_object('ok', false, 'reason', case when p.alerts_paid_until is not null then 'expired' else 'none' end,
                            'role', p.role, 'until', p.alerts_paid_until)
  end
  from (select 1) one left join profiles p on p.id = p_uid
$$;
revoke all on function public.alerts_access_of(uuid) from public, anon, authenticated;

create or replace function public.my_alerts_access() returns jsonb
language sql stable security definer set search_path = public as
$$ select alerts_access_of(auth.uid()) $$;
revoke all on function public.my_alerts_access() from public;
grant execute on function public.my_alerts_access() to authenticated;

-- client submits a payment (TXID) for staff to check
create or replace function public.alerts_submit_payment(p_network text, p_txid text) returns bigint
language plpgsql security definer set search_path = public as $$
declare plan jsonb := alerts_plan(); tx text := btrim(coalesce(p_txid, '')); new_id bigint;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if tx !~ '^[A-Za-z0-9]{20,120}$' then raise exception 'bad txid'; end if;
  if not exists (select 1 from jsonb_array_elements(coalesce(plan->'wallets', '[]')) w where w->>'network' = p_network) then
    raise exception 'bad network';
  end if;
  if (select count(*) from alerts_payments where user_id = auth.uid() and status = 'pending') >= 3 then
    raise exception 'too many pending';
  end if;
  if exists (select 1 from alerts_payments where lower(txid) = lower(tx)) then raise exception 'txid already used'; end if;
  insert into alerts_payments (user_id, amount_usd, network, txid, days)
  values (auth.uid(), coalesce((plan->>'price_usd')::numeric, 0), p_network, tx, coalesce((plan->>'days')::int, 30))
  returning id into new_id;
  return new_id;
end $$;
revoke all on function public.alerts_submit_payment(text, text) from public;
grant execute on function public.alerts_submit_payment(text, text) to authenticated;

-- staff: approve (extends from today or from the current end date, whichever is later) / reject
create or replace function public.alerts_approve_payment(p_id bigint, p_days int default null) returns timestamptz
language plpgsql security definer set search_path = public as $$
declare pay alerts_payments; until timestamptz;
begin
  if coalesce(my_role(), '') not in ('manager','admin') then raise exception 'not allowed'; end if;
  select * into pay from alerts_payments where id = p_id for update;
  if pay.id is null or pay.status <> 'pending' then raise exception 'not pending'; end if;
  update profiles set alerts_paid_until = greatest(now(), coalesce(alerts_paid_until, now()))
                                          + make_interval(days => coalesce(p_days, pay.days))
  where id = pay.user_id returning alerts_paid_until into until;
  update alerts_payments set status = 'approved', days = coalesce(p_days, pay.days),
         decided_by = auth.uid(), decided_at = now() where id = p_id;
  return until;
end $$;

create or replace function public.alerts_reject_payment(p_id bigint, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(my_role(), '') not in ('manager','admin') then raise exception 'not allowed'; end if;
  update alerts_payments set status = 'rejected', note = left(p_note, 300), decided_by = auth.uid(), decided_at = now()
  where id = p_id and status = 'pending';
end $$;

-- staff: give days by hand (gift, trial), or 0 = stop now
create or replace function public.alerts_grant_days(p_user uuid, p_days int) returns timestamptz
language plpgsql security definer set search_path = public as $$
declare until timestamptz;
begin
  if coalesce(my_role(), '') not in ('manager','admin') then raise exception 'not allowed'; end if;
  if p_days < 0 or p_days > 3660 then raise exception 'bad days'; end if;
  update profiles set alerts_paid_until = case when p_days = 0 then now()
           else greatest(now(), coalesce(alerts_paid_until, now())) + make_interval(days => p_days) end
  where id = p_user returning alerts_paid_until into until;
  return until;
end $$;

revoke all on function public.alerts_approve_payment(bigint, int) from public;
revoke all on function public.alerts_reject_payment(bigint, text) from public;
revoke all on function public.alerts_grant_days(uuid, int) from public;
grant execute on function public.alerts_approve_payment(bigint, int) to authenticated;
grant execute on function public.alerts_reject_payment(bigint, text) to authenticated;
grant execute on function public.alerts_grant_days(uuid, int) to authenticated;

-- ---------- login hand-off ----------
create table if not exists public.alerts_codes (
  code        text primary key,
  user_id     uuid not null references auth.users(id) on delete cascade,
  expires_at  timestamptz not null
);
alter table public.alerts_codes enable row level security;   -- no policies: functions only
revoke all on public.alerts_codes from anon, authenticated;

create or replace function public.alerts_issue_code() returns text
language plpgsql security definer set search_path = public as $$
declare c text := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if not (alerts_access_of(auth.uid())->>'ok')::boolean then raise exception 'no access'; end if;
  delete from alerts_codes where expires_at < now() or user_id = auth.uid();
  insert into alerts_codes values (c, auth.uid(), now() + interval '2 minutes');
  return c;
end $$;
revoke all on function public.alerts_issue_code() from public;
grant execute on function public.alerts_issue_code() to authenticated;

-- alerts server: code -> who (one use only)
create or replace function public.alerts_redeem_code(p_token text, p_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare uid uuid;
begin
  perform alerts_check(p_token);
  delete from alerts_codes where code = p_code and expires_at > now() returning user_id into uid;
  if uid is null then return null; end if;
  return (select jsonb_build_object('user_id', p.id,
            'name', coalesce(nullif(p.display_name, ''), p.username, split_part(u.email, '@', 1)),
            'access', alerts_access_of(p.id))
          from profiles p join auth.users u on u.id = p.id where p.id = uid);
end $$;

-- alerts server: re-check signed-in users every few minutes -> {"<uuid>": {ok, reason, role, until}}
create or replace function public.alerts_check_users(p_token text, p_ids uuid[]) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform alerts_check(p_token);
  return coalesce((select jsonb_object_agg(i, alerts_access_of(i)) from unnest(p_ids) i), '{}'::jsonb);
end $$;

revoke all on function public.alerts_redeem_code(text, text) from public;
revoke all on function public.alerts_check_users(text, uuid[]) from public;
grant execute on function public.alerts_redeem_code(text, text) to anon, authenticated;
grant execute on function public.alerts_check_users(text, uuid[]) to anon, authenticated;
