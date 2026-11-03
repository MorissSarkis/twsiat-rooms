-- 036: once a signal reaches TP1 it counts as a win. Channel, Telegram DMs and phone notifications say only
-- "TP1 reached" (no "move the stop" line), and nothing more is sent for that signal afterwards except TP2.
-- Same functions as in 033, only these lines changed. Safe to run more than once.

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
  elsif new.state is distinct from old.state and coalesce(new.closed_reason, '') <> 'manual'
        and (new.tp1_at is null or new.state in ('tp1', 'tp2')) then
    msg := case new.state
      when 'open'    then format('⚡ %s %s · اتفعّلت الصفقة', name, dir)
      when 'tp1'     then format('✅ %s %s · تحقق الهدف 1', name, dir)
      when 'tp2'     then case when new.tp2 is null then format('✅ %s %s · تحقق الهدف', name, dir) else format('✅✅ %s %s · تحقق الهدف 2', name, dir) end
      when 'sl'      then case when new.stop_loss is distinct from new.orig_stop then format('❌ %s %s · ضربت وقف الخسارة المعدّل', name, dir) else format('❌ %s %s · ضربت وقف الخسارة', name, dir) end
      when 'be'      then format('↩️ %s %s · ضربت الستوب المعدّل (بدون خسارة)', name, dir)
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

create or replace function public.signal_push() returns trigger
language plpgsql security definer set search_path = public as $$
declare name text := coalesce((select x->>'name' from jsonb_array_elements((select value from app_config where key = 'symbols')) x where x->>'code' = new.symbol), new.symbol);
        dir text := case when new.side = 'BUY' then 'شراء' else 'بيع' end;
        t text; b text; users uuid[]; r int := (select min(x) from unnest(new.rooms) x);
begin
  if tg_op = 'INSERT' then
    t := format('🔔 توصية جديدة · %s (%s)', name, dir);
    b := 'الدخول والستوب والأهداف وحجم اللوت المناسب لحسابك داخل غرفتك.';
  elsif new.state is distinct from old.state and coalesce(new.closed_reason, '') <> 'manual'
        and (new.tp1_at is null or new.state in ('tp1', 'tp2')) then
    t := case new.state
      when 'open'    then format('⚡ %s %s · اتفعّلت الصفقة', name, dir)
      when 'tp1'     then format('✅ %s %s · تحقق الهدف 1', name, dir)
      when 'tp2'     then format('✅✅ %s %s · تحقق الهدف%s', name, dir, case when new.tp2 is null then '' else ' 2' end)
      when 'sl'      then format('❌ %s %s · ضربت وقف الخسارة', name, dir)
      when 'be'      then format('↩️ %s %s · ضربت الستوب بدون خسارة', name, dir)
      when 'expired' then format('⏹ %s %s · الأمر المعلّق انلغى', name, dir)
      when 'closed'  then format('⏹ %s %s · أُغلقت بعد 5 أيام', name, dir)
      else null end;
    b := 'التفاصيل بالغرفة.';
  end if;
  if t is null then return new; end if;
  select array_agg(p.id) into users from profiles p where p.ib_verified and p.room = any(new.rooms);
  perform push_send(users, t, b, '/rooms?room=' || coalesce(r, 1)::text || '#s' || new.id, 'sig' || new.id);
  return new;
end $$;
