-- 007: Telegram messages without price levels (entry / SL / TP stay inside the rooms only).
-- The channel can be public: it tells people something happened and sends them to the site.
-- Site link is read from app_config 'site_url' (set it once, see the bottom of this file).

create or replace function public.signal_notify() returns trigger
language plpgsql security definer set search_path = public as $$
declare name text := case when new.symbol = 'XAUUSD' then 'الذهب' else new.symbol end;
        dir  text := case when new.side = 'BUY' then 'شراء' else 'بيع' end;
        url  text := (select value #>> '{}' from app_config where key = 'site_url');
        msg  text;
begin
  if tg_op = 'INSERT' then
    msg := format(E'🔔 توصية جديدة على %s (%s)\nالدخول والستوب والأهداف وحجم اللوت المناسب لحسابك داخل غرفتك.', name, dir);
  elsif new.state is distinct from old.state then
    msg := case new.state
      when 'open'    then format('⚡ %s %s · اتفعّلت الصفقة', name, dir)
      when 'tp1'     then format('✅ %s %s · تحقق الهدف 1 — انقل الستوب لنقطة الدخول', name, dir)
      when 'tp2'     then format('✅✅ %s %s · تحقق الهدف 2', name, dir)
      when 'sl'      then format('❌ %s %s · ضربت وقف الخسارة', name, dir)
      when 'be'      then format('↩️ %s %s · رجعت لنقطة الدخول بعد الهدف 1 (ربح على نص الصفقة)', name, dir)
      when 'expired' then format('⏹ %s %s · الأمر المعلّق ما اتفعّل وانلغى', name, dir)
      when 'closed'  then format('⏹ %s %s · أُغلقت بعد 5 أيام', name, dir)
      else null end;
  end if;
  if msg is not null then
    if url is not null then msg := msg || E'\n' || url; end if;
    perform telegram_send(msg);
  end if;
  return new;
end $$;

-- Set the site link once (replace with the real address):
-- insert into app_config (key, value) values ('site_url', to_jsonb('https://YOUR-SITE'::text))
--   on conflict (key) do update set value = excluded.value;
