-- 025: WhatsApp number at sign-up (needed to find clients under our agency at the brokers)
--  * the sign-up form sends it with the account; the new-user trigger saves it on the profile
--  * members without a number (older sign-ups, Google) add it once from the home page
-- Requires 024. Safe to run more than once.

-- "+971 50-123 4567" / "00971501234567" -> "+971501234567"; null when it doesn't look like an international number
create or replace function public.norm_phone(p text) returns text
language plpgsql immutable as $$
declare ph text := regexp_replace(coalesce(p, ''), '[\s\-\(\)\.]', '', 'g');
begin
  if ph like '00%' then ph := '+' || substr(ph, 3); end if;
  if ph ~ '^\+[1-9][0-9]{7,14}$' then return ph; end if;
  return null;
end $$;

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name, phone)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)),
          public.norm_phone(new.raw_user_meta_data->>'phone'));
  return new;
end $$;

-- member adds or changes their own number
create or replace function public.set_my_phone(p_phone text) returns text
language plpgsql security definer set search_path = public as $$
declare ph text := norm_phone(p_phone);
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  if ph is null then raise exception 'bad phone'; end if;
  update profiles set phone = ph where id = auth.uid();
  return ph;
end $$;
revoke all on function public.set_my_phone(text) from public;
grant execute on function public.set_my_phone(text) to authenticated;

-- the activation form now always needs a number
create or replace function public.submit_activation(p_broker text, p_account text, p_has_ib boolean, p_phone text)
returns void language plpgsql security definer set search_path = public as $$
declare ph text := norm_phone(p_phone); acc text := btrim(coalesce(p_account, '')); cur text;
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  select phone into cur from profiles where id = auth.uid();
  if btrim(coalesce(p_phone, '')) <> '' and ph is null then raise exception 'bad phone'; end if;
  if coalesce(ph, cur) is null then raise exception 'phone required'; end if;
  if p_has_ib is true and acc !~ '^[0-9]{4,15}$' then raise exception 'bad account'; end if;
  if acc <> '' and acc !~ '^[0-9]{4,15}$' then raise exception 'bad account'; end if;
  perform set_config('twsiat.sys', '1', true);
  update profiles set broker = nullif(btrim(coalesce(p_broker, '')), ''), broker_account = nullif(acc, ''),
         has_ib_account = coalesce(p_has_ib, false), phone = coalesce(ph, phone),
         activation_requested_at = now(), activation_rejected_at = null, activation_note = null
  where id = auth.uid();
end $$;
revoke all on function public.submit_activation(text, text, boolean, text) from public;
grant execute on function public.submit_activation(text, text, boolean, text) to authenticated;

-- one-time code for the alerts app also needs a number on file (staff excepted)
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
