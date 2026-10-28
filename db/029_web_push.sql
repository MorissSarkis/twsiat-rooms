-- 029: phone notifications (Web Push) for the rooms — free, no app store, no Telegram needed.
-- The database decides WHO gets WHAT; the site (rooms.twsiat.com/api/push/*) encrypts and sends.
-- The VAPID keys are created by the site on first run and kept here (app_secrets), never in the code.
-- Run AFTER the site update is live (the last line asks the site to create the keys). Safe to run more than once.

create table if not exists public.push_subs (
  id         bigserial primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  endpoint   text not null unique,
  p256dh     text not null,
  auth       text not null,
  ua         text,
  created_at timestamptz not null default now(),
  fails      int not null default 0
);
alter table public.push_subs enable row level security;
drop policy if exists "own push subs" on public.push_subs;
create policy "own push subs" on public.push_subs for all using (user_id = auth.uid()) with check (user_id = auth.uid());
grant select, insert, update, delete on public.push_subs to authenticated;
grant usage on sequence public.push_subs_id_seq to authenticated;

insert into public.app_secrets (name, value) values ('push_secret', replace(gen_random_uuid()::text, '-', ''))
on conflict (name) do nothing;

-- public key for the browser (null until the site created the keys)
create or replace function public.push_public_key() returns text
language sql stable security definer set search_path = public as $$
  select value from app_secrets where name = 'vapid_public';
$$;
grant execute on function public.push_public_key() to anon, authenticated;

-- the site stores the keys it generated (only once, only with the secret)
create or replace function public.push_init_keys(p_secret text, p_public text, p_private text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if p_secret is distinct from (select value from app_secrets where name = 'push_secret') then return false; end if;
  if exists (select 1 from app_secrets where name = 'vapid_public') then return false; end if;
  insert into app_secrets values ('vapid_public', p_public), ('vapid_private', p_private);
  return true;
end $$;
grant execute on function public.push_init_keys(text, text, text) to anon, authenticated;

-- the site asks: keys + subscriptions of these users
create or replace function public.push_targets(p_secret text, p_users uuid[]) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if p_secret is distinct from (select value from app_secrets where name = 'push_secret') then return null; end if;
  return jsonb_build_object(
    'public',  (select value from app_secrets where name = 'vapid_public'),
    'private', (select value from app_secrets where name = 'vapid_private'),
    'subs', (select coalesce(jsonb_agg(jsonb_build_object('endpoint', endpoint, 'keys', jsonb_build_object('p256dh', p256dh, 'auth', auth))), '[]')
             from push_subs where user_id = any(p_users)));
end $$;
grant execute on function public.push_targets(text, uuid[]) to anon, authenticated;

-- the site reports phones that unsubscribed / expired
create or replace function public.push_gone(p_secret text, p_endpoints text[]) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_secret is distinct from (select value from app_secrets where name = 'push_secret') then return; end if;
  delete from push_subs where endpoint = any(p_endpoints);
end $$;
grant execute on function public.push_gone(text, text[]) to anon, authenticated;

-- queue one notification for some users (the site does the sending)
create or replace function public.push_send(p_users uuid[], p_title text, p_body text, p_url text, p_tag text default null) returns void
language plpgsql security definer set search_path = public as $$
declare site text := rtrim(coalesce((select value #>> '{}' from app_config where key = 'site_url'), ''), '/');
begin
  if p_users is null or cardinality(p_users) = 0 or site = '' then return; end if;
  if not exists (select 1 from push_subs where user_id = any(p_users)) then return; end if;
  perform net.http_post(
    url := site || '/api/push/send',
    body := jsonb_build_object('secret', (select value from app_secrets where name = 'push_secret'),
                               'users', to_jsonb(p_users), 'title', p_title, 'body', p_body, 'url', p_url, 'tag', p_tag),
    headers := '{"Content-Type":"application/json"}'::jsonb);
end $$;
revoke all on function public.push_send(uuid[], text, text, text, text) from public, anon, authenticated;

-- signals → members of that room
create or replace function public.signal_push() returns trigger
language plpgsql security definer set search_path = public as $$
declare name text := coalesce((select x->>'name' from jsonb_array_elements((select value from app_config where key = 'symbols')) x where x->>'code' = new.symbol), new.symbol);
        dir text := case when new.side = 'BUY' then 'شراء' else 'بيع' end;
        t text; b text; users uuid[]; r int := (select min(x) from unnest(new.rooms) x);
begin
  if tg_op = 'INSERT' then
    t := format('🔔 توصية جديدة · %s (%s)', name, dir);
    b := 'الدخول والستوب والأهداف وحجم اللوت المناسب لحسابك داخل غرفتك.';
  elsif new.state is distinct from old.state then
    t := case new.state
      when 'open'    then format('⚡ %s %s · اتفعّلت الصفقة', name, dir)
      when 'tp1'     then format('✅ %s %s · تحقق الهدف 1', name, dir)
      when 'tp2'     then format('✅✅ %s %s · تحقق الهدف%s', name, dir, case when new.tp2 is null then '' else ' 2' end)
      when 'sl'      then format('❌ %s %s · ضربت وقف الخسارة', name, dir)
      when 'be'      then format('↩️ %s %s · رجعت لنقطة الدخول', name, dir)
      when 'expired' then format('⏹ %s %s · الأمر المعلّق انلغى', name, dir)
      when 'closed'  then format('⏹ %s %s · أُغلقت بعد 5 أيام', name, dir)
      else null end;
    b := case new.state when 'tp1' then 'انقل الستوب لنقطة الدخول. التفاصيل بالغرفة.' else 'التفاصيل بالغرفة.' end;
  end if;
  if t is null then return new; end if;
  select array_agg(p.id) into users from profiles p
  where p.ib_verified and p.room = any(new.rooms);
  perform push_send(users, t, b, '/rooms?room=' || coalesce(r, 1)::text, 'sig' || new.id);
  return new;
end $$;
drop trigger if exists signals_push on public.signals;
create trigger signals_push after insert or update of state on public.signals
  for each row when (not new.shadow) execute function public.signal_push();

-- account activated / moved to another room
create or replace function public.profile_push() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.ib_verified and not coalesce(old.ib_verified, false) then
    perform push_send(array[new.id], 'تم تفعيل حسابك ✅',
      case new.room when 2 then 'غرفتك: الحسابات الكبيرة. ادخل ووافق على شروط الغرفة.' else 'غرفتك: الحسابات الصغيرة. ادخل ووافق على شروط الغرفة.' end, '/rooms');
  elsif new.ib_verified and old.ib_verified and new.room is distinct from old.room then
    perform push_send(array[new.id],
      case new.room when 2 then 'تم نقلك لغرفة الحسابات الكبيرة ✅' else 'تم نقلك لغرفة الحسابات الصغيرة' end,
      'ادخل الغرفة وشوف التوصيات.', '/rooms');
  end if;
  return new;
end $$;
drop trigger if exists profiles_push on public.profiles;
create trigger profiles_push after update of ib_verified, room on public.profiles
  for each row execute function public.profile_push();

-- ask the site to create the keys (needs the site update to be live)
select net.http_post(
  url := rtrim(coalesce((select value #>> '{}' from public.app_config where key = 'site_url'), ''), '/') || '/api/push/init',
  body := jsonb_build_object('secret', (select value from public.app_secrets where name = 'push_secret')),
  headers := '{"Content-Type":"application/json"}'::jsonb) as asked_site_for_keys;
