-- 002: client activation requests, staff permissions, publishing signals.

-- Clients may edit their own name/username and submit broker details for verification.
-- Protected fields (role, verification, room, balance) can only be changed by staff.
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
       or new.verified_by is distinct from old.verified_by then
      raise exception 'not allowed';
    end if;
  end if;
  return new;
end $$;

create trigger profiles_protect before update on public.profiles
  for each row execute function public.protect_profile_fields();

-- activation request timestamp, so staff see a queue
alter table public.profiles add column if not exists activation_requested_at timestamptz;

grant update on public.profiles to authenticated;
create policy "own profile update" on public.profiles for update
  using (id = auth.uid()) with check (id = auth.uid());
create policy "staff profile update" on public.profiles for update
  using (public.my_role() in ('manager','admin')) with check (true);

-- staff publish approved suggestions as signals
grant insert, update on public.signals to authenticated;
create policy "staff publish" on public.signals for insert
  with check (public.my_role() in ('manager','admin'));
create policy "staff update signals" on public.signals for update
  using (public.my_role() in ('manager','admin'));

-- staff can read consents (for audit)
create policy "staff read consents" on public.consents for select
  using (public.my_role() in ('manager','admin'));
