-- 017: personal Telegram alerts. A member presses "فعّل إشعارات تيليجرام" on the site → opens @twsiat_alerts_bot
-- with a private code → presses Start → the bot links that chat to the member's account.
-- After that the member gets, in a private chat: account activated, new signals for HIS room, and their updates.
-- The bot token never leaves the database: the webhook is set from here, and the site only forwards updates
-- (checked with a random secret that Telegram sends back in a header).
--
-- After running this file, run once:   select public.tg_set_webhook();

alter table public.profiles add column if not exists telegram_chat_id bigint;
alter table public.profiles add column if not exists tg_link_code text unique;
alter table public.profiles add column if not exists telegram_linked_at timestamptz;

insert into public.app_secrets (name, value) values ('tg_webhook_secret', replace(gen_random_uuid()::text, '-', ''))
on conflict (name) do nothing;
insert into public.app_config values ('tg_bot_username', '"twsiat_alerts_bot"')
on conflict (key) do update set value = excluded.value;

-- Members must not set these columns themselves.
create or replace function public.profiles_guard_tg() returns trigger
language plpgsql as $$
begin
  -- only the functions below (which set twsiat.tg) may change these columns when a user is signed in
  if auth.uid() is not null and coalesce(current_setting('twsiat.tg', true), '') <> '1' then
    new.telegram_chat_id := old.telegram_chat_id;
    new.tg_link_code := old.tg_link_code;
    new.telegram_linked_at := old.telegram_linked_at;
  end if;
  return new;
end $$;
drop trigger if exists profiles_guard_tg on public.profiles;
create trigger profiles_guard_tg before update on public.profiles
  for each row execute function public.profiles_guard_tg();

-- Private message to one chat.
create or replace function public.telegram_dm(p_chat bigint, p_text text) returns void
language plpgsql security definer set search_path = public as $$
declare tok text := (select value from app_secrets where name = 'telegram_bot_token');
begin
  if tok is null or p_chat is null then return; end if;
  perform net.http_post(
    url := 'https://api.telegram.org/bot' || tok || '/sendMessage',
    body := jsonb_build_object('chat_id', p_chat, 'text', p_text, 'disable_web_page_preview', true),
    headers := '{"Content-Type":"application/json"}'::jsonb);
end $$;
revoke all on function public.telegram_dm(bigint, text) from public, anon, authenticated;

-- The signed-in member's personal link to the bot (null once linked).
create or replace function public.my_telegram_link() returns text
language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); c text; linked bigint; bot text := (select value #>> '{}' from app_config where key = 'tg_bot_username');
begin
  if me is null then return null; end if;
  select tg_link_code, telegram_chat_id into c, linked from profiles where id = me;
  if linked is not null then return null; end if;
  if c is null then
    c := replace(gen_random_uuid()::text, '-', '');
    perform set_config('twsiat.tg', '1', true);
    update profiles set tg_link_code = c where id = me;
  end if;
  return 'https://t.me/' || bot || '?start=' || c;
end $$;
revoke all on function public.my_telegram_link() from public, anon;
grant execute on function public.my_telegram_link() to authenticated;

-- Called by the site for every update Telegram posts to the webhook.
create or replace function public.tg_webhook(p_secret text, p_update jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare chat bigint := nullif(p_update #>> '{message,chat,id}', '')::bigint;
        txt  text := coalesce(p_update #>> '{message,text}', '');
        typ  text := p_update #>> '{message,chat,type}';
        code text; who record; url text := coalesce((select value #>> '{}' from app_config where key = 'site_url'), '');
begin
  if p_secret is null or p_secret <> (select value from app_secrets where name = 'tg_webhook_secret') then return; end if;
  if chat is null or typ is distinct from 'private' then return; end if;
  perform set_config('twsiat.tg', '1', true);

  if txt ~ '^/start(@\w+)?\s+[0-9a-f]{32}$' then
    code := substring(txt from '([0-9a-f]{32})$');
    select id, display_name, ib_verified, room into who from profiles where tg_link_code = code;
    if who.id is null then
      perform telegram_dm(chat, 'الرابط مش صالح. افتح الموقع وادخل على حسابك واضغط «فعّل إشعارات تيليجرام» من جديد.' || E'\n' || url);
      return;
    end if;
    update profiles set telegram_chat_id = null, telegram_linked_at = null where telegram_chat_id = chat and id <> who.id;
    update profiles set telegram_chat_id = chat, telegram_linked_at = now(), tg_link_code = null where id = who.id;
    perform telegram_dm(chat, format(E'أهلاً %s 👋\nتم ربط تيليجرام بحسابك بغرفة التداول ✅\n%s\nلإيقاف الإشعارات ابعت /stop',
      coalesce(who.display_name, ''),
      case when who.ib_verified then 'رح توصلك هون توصيات غرفتك وتحديثاتها أول بأول.'
           else 'رح نبعتلك هون أول ما يتفعّل حسابك، وبعدها توصيات غرفتك أول بأول.' end));
  elsif txt ~ '^/stop' then
    update profiles set telegram_chat_id = null, telegram_linked_at = null where telegram_chat_id = chat;
    perform telegram_dm(chat, 'وقّفنا الإشعارات. لترجّعها افتح الموقع واضغط «فعّل إشعارات تيليجرام».');
  elsif txt ~ '^/start' then
    perform telegram_dm(chat, 'أهلاً! لتوصلك إشعارات غرفتك، ادخل على حسابك بالموقع واضغط «فعّل إشعارات تيليجرام».' || E'\n' || url);
  end if;
end $$;
revoke all on function public.tg_webhook(text, jsonb) from public;
grant execute on function public.tg_webhook(text, jsonb) to anon, authenticated;

-- Point the bot at the site (run once after deploy; again if the site address changes).
create or replace function public.tg_set_webhook() returns bigint
language plpgsql security definer set search_path = public as $$
declare tok text := (select value from app_secrets where name = 'telegram_bot_token');
        sec text := (select value from app_secrets where name = 'tg_webhook_secret');
        url text := rtrim(coalesce((select value #>> '{}' from app_config where key = 'site_url'), ''), '/') || '/api/telegram';
begin
  return net.http_post(
    url := 'https://api.telegram.org/bot' || tok || '/setWebhook',
    body := jsonb_build_object('url', url, 'secret_token', sec, 'allowed_updates', jsonb_build_array('message'), 'drop_pending_updates', true),
    headers := '{"Content-Type":"application/json"}'::jsonb);
end $$;
revoke all on function public.tg_set_webhook() from public, anon, authenticated;

-- Activation: email (016) + Telegram if linked.
create or replace function public.activation_tg() returns trigger
language plpgsql security definer set search_path = public as $$
declare url text := coalesce((select value #>> '{}' from app_config where key = 'site_url'), '');
begin
  if new.ib_verified and not coalesce(old.ib_verified, false) and new.telegram_chat_id is not null then
    perform telegram_dm(new.telegram_chat_id, format(E'تم تفعيل حسابك ✅\nغرفتك: %s\nادخل ووافق على شروط الغرفة وبتشوف التوصيات:\n%srooms',
      case new.room when 2 then 'الحسابات الكبيرة (1,000$ وأكثر)' else 'الحسابات الصغيرة (أقل من 1,000$)' end, url));
  end if;
  return new;
end $$;
drop trigger if exists profiles_activation_tg on public.profiles;
create trigger profiles_activation_tg after update of ib_verified on public.profiles
  for each row execute function public.activation_tg();

-- Signals: channel message as before + the same message privately to linked members of that room.
create or replace function public.signal_notify() returns trigger
language plpgsql security definer set search_path = public as $$
declare name text := coalesce((select x->>'name' from jsonb_array_elements((select value from app_config where key = 'symbols')) x where x->>'code' = new.symbol), new.symbol);
        dir  text := case when new.side = 'BUY' then 'شراء' else 'بيع' end;
        url  text := (select value #>> '{}' from app_config where key = 'site_url');
        msg  text; m record;
begin
  if tg_op = 'INSERT' then
    msg := format(E'🔔 توصية جديدة على %s (%s)%s\nالدخول والستوب والأهداف وحجم اللوت المناسب لحسابك داخل غرفتك.', name, dir,
                  case when new.credit_username is not null then E'\n💡 فكرة من العضو @' || new.credit_username else '' end);
  elsif new.state is distinct from old.state then
    msg := case new.state
      when 'open'    then format('⚡ %s %s · اتفعّلت الصفقة', name, dir)
      when 'tp1'     then format('✅ %s %s · تحقق الهدف 1 — انقل الستوب لنقطة الدخول', name, dir)
      when 'tp2'     then case when new.tp2 is null then format('✅ %s %s · تحقق الهدف', name, dir) else format('✅✅ %s %s · تحقق الهدف 2', name, dir) end
      when 'sl'      then format('❌ %s %s · ضربت وقف الخسارة', name, dir)
      when 'be'      then format('↩️ %s %s · رجعت لنقطة الدخول بعد الهدف 1 (ربح على نص الصفقة)', name, dir)
      when 'expired' then format('⏹ %s %s · الأمر المعلّق ما اتفعّل وانلغى', name, dir)
      when 'closed'  then format('⏹ %s %s · أُغلقت بعد 5 أيام', name, dir)
      else null end;
  end if;
  if msg is not null then
    if url is not null then msg := msg || E'\n' || url; end if;
    perform telegram_send(msg);
    for m in select p.telegram_chat_id from profiles p
             where p.telegram_chat_id is not null and p.ib_verified and p.room = any(new.rooms) loop
      perform telegram_dm(m.telegram_chat_id, msg);
    end loop;
  end if;
  return new;
end $$;
