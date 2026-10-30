-- 033: updates on a published signal — move the stop, change the targets, add a comment, or close it now.
--  * every update is kept in signal_updates and shown under the signal in the room (time + text)
--  * members of the room get it on Telegram (private) and as a phone notification; the public channel only
--    gets "there is an update on <symbol>" (no levels, as before)
--  * results stay honest: R is always measured on the ORIGINAL stop distance (orig_stop); a moved stop that is
--    hit gives its real result (e.g. -0.5R, 0R, +0.8R), and "close now" closes at the last bridge price
-- Requires 001–032. Safe to run more than once.

alter table public.signals add column if not exists orig_stop numeric;
alter table public.signals add column if not exists closed_reason text;          -- 'time' | 'manual' | null
update public.signals set orig_stop = stop_loss where orig_stop is null;

create or replace function public.signals_orig_stop() returns trigger
language plpgsql as $$ begin new.orig_stop := coalesce(new.orig_stop, new.stop_loss); return new; end $$;
drop trigger if exists signals_orig_stop on public.signals;
create trigger signals_orig_stop before insert on public.signals for each row execute function public.signals_orig_stop();

create table if not exists public.signal_updates (
  id         bigserial primary key,
  signal_id  bigint not null references public.signals(id) on delete cascade,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id),
  kind       text not null check (kind in ('note','levels','close')),
  text       text not null
);
create index if not exists signal_updates_signal on public.signal_updates(signal_id, created_at);
alter table public.signal_updates enable row level security;
drop policy if exists "read updates of readable signals" on public.signal_updates;
create policy "read updates of readable signals" on public.signal_updates for select
  using (exists (select 1 from public.signals s where s.id = signal_id));   -- the signals policy decides who sees it
grant select on public.signal_updates to authenticated;

-- tracking: stop can be moved by staff; R stays on the original risk
create or replace function public.engine_track(p_now timestamptz default now())
returns integer language plpgsql security definer set search_path = public as $$
declare
  sig record; b record; buy boolean; stop numeric; risk numeric; r1 numeric; r2 numeric; rs numeric;
  lo numeric; hi numeric; hold interval; n int := 0; done boolean;
begin
  hold := make_interval(days => ((select value from app_config where key = 'rules')->>'max_hold_days')::int);
  for sig in select * from signals where state in ('waiting','open','tp1') order by id loop
    buy := sig.side = 'BUY';
    risk := abs(sig.entry - coalesce(sig.orig_stop, sig.stop_loss));
    if risk = 0 then continue; end if;
    r1 := abs(sig.tp1 - sig.entry) / risk;
    r2 := case when sig.tp2 is null then null else abs(sig.tp2 - sig.entry) / risk end;
    -- after TP1 the stop is at least at the entry; staff may have moved it further into profit
    stop := case when sig.state = 'tp1'
                 then case when buy then greatest(sig.entry, sig.stop_loss) else least(sig.entry, sig.stop_loss) end
                 else sig.stop_loss end;
    done := false;
    for b in select * from prices_m5
             where symbol = sig.symbol and t > coalesce(sig.last_bar_t, sig.published_at - interval '5 minutes')
               and t <= p_now
             order by t loop
      sig.last_bar_t := b.t;
      lo := case when buy then b.low else b.low + b.spread end;
      hi := case when buy then b.high else b.high + b.spread end;

      if sig.state = 'waiting' then
        if sig.expires_at is not null and b.t >= sig.expires_at then
          sig.state := 'expired'; sig.closed_at := b.t; done := true; exit;
        end if;
        if (buy and b.low + b.spread <= sig.entry) or ((not buy) and b.high >= sig.entry) then
          sig.state := 'open'; sig.filled_at := b.t;
        else
          continue;
        end if;
      end if;

      if b.t > sig.filled_at + hold then
        if sig.state = 'tp1' then
          sig.result_r_partial := round(0.5 * r1 + 0.5 * ((case when buy then b.close - sig.entry else sig.entry - b.close end) / risk), 3);
        else
          sig.result_r_tp1only := round((case when buy then b.close - sig.entry else sig.entry - b.close end) / risk, 3);
          sig.result_r_partial := sig.result_r_tp1only;
        end if;
        sig.state := 'closed'; sig.closed_reason := 'time'; sig.closed_at := b.t; done := true; exit;
      end if;

      if (buy and lo <= stop) or ((not buy) and hi >= stop) then
        rs := round((case when buy then stop - sig.entry else sig.entry - stop end) / risk, 3);
        if sig.state = 'tp1' then
          sig.state := 'be'; sig.result_r_partial := round(0.5 * r1 + 0.5 * rs, 3);
        else
          sig.state := case when rs < 0 then 'sl' else 'be' end;
          sig.result_r_tp1only := rs; sig.result_r_partial := rs;
        end if;
        sig.closed_at := b.t; done := true; exit;
      end if;

      if b.t > sig.filled_at then
        if sig.state = 'open' and ((buy and hi >= sig.tp1) or ((not buy) and lo <= sig.tp1)) then
          sig.state := 'tp1'; sig.tp1_at := b.t; sig.result_r_tp1only := round(r1, 3);
          stop := case when buy then greatest(sig.entry, sig.stop_loss) else least(sig.entry, sig.stop_loss) end;
          sig.stop_moved_to := stop;
          if r2 is null then
            sig.result_r_partial := round(r1, 3); sig.state := 'tp2'; sig.closed_at := b.t; done := true; exit;
          end if;
        end if;
        if sig.state = 'tp1' and ((buy and hi >= sig.tp2) or ((not buy) and lo <= sig.tp2)) then
          sig.state := 'tp2'; sig.result_r_partial := round(0.5 * r1 + 0.5 * r2, 3);
          sig.closed_at := b.t; done := true; exit;
        end if;
      end if;
    end loop;

    update signals set state = sig.state, filled_at = sig.filled_at, tp1_at = sig.tp1_at, closed_at = sig.closed_at,
           result_r_tp1only = sig.result_r_tp1only, result_r_partial = sig.result_r_partial,
           stop_moved_to = sig.stop_moved_to, last_bar_t = sig.last_bar_t, closed_reason = sig.closed_reason
     where id = sig.id;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.engine_track(timestamptz) from public, anon, authenticated;

-- staff: update a live signal. Empty values = unchanged. p_close = close it now at the last price.
create or replace function public.staff_update_signal(p_id bigint, p_sl numeric, p_tp1 numeric, p_tp2 numeric,
                                                      p_note text, p_close boolean default false)
returns text language plpgsql security definer set search_path = public as $$
declare s record; buy boolean; sl numeric; t1 numeric; t2 numeric; parts text[] := '{}'; dg int; risk numeric;
        px numeric; rr numeric; r1 numeric; note text := nullif(trim(coalesce(p_note, '')), '');
begin
  if coalesce(my_role(), '') not in ('manager','admin') then raise exception 'not allowed'; end if;
  select * into s from signals where id = p_id for update;
  if s.id is null or s.shadow then raise exception 'التوصية مش موجودة'; end if;
  if s.state not in ('waiting','open','tp1') then raise exception 'التوصية مسكّرة، ما بتنعدّل'; end if;
  buy := s.side = 'BUY';
  dg := coalesce((select (x->>'digits')::int from jsonb_array_elements((select value from app_config where key = 'symbols')) x where x->>'code' = s.symbol), 2);

  if coalesce(p_close, false) then
    select close into px from prices_m5 where symbol = s.symbol order by t desc limit 1;
    if s.state = 'waiting' then
      update signals set state = 'expired', closed_at = now(), closed_reason = 'manual' where id = p_id;
      insert into signal_updates(signal_id, created_by, kind, text)
        values (p_id, auth.uid(), 'close', coalesce(note || E'\n', '') || 'انلغى الأمر المعلّق قبل ما يتفعّل.');
      return 'cancelled';
    end if;
    if px is null then raise exception 'ما في سعر حالي للأداة'; end if;
    risk := abs(s.entry - coalesce(s.orig_stop, s.stop_loss));
    rr := round((case when buy then px - s.entry else s.entry - px end) / risk, 3);
    r1 := abs(s.tp1 - s.entry) / risk;
    update signals set state = 'closed', closed_reason = 'manual', closed_at = now(),
           result_r_tp1only = case when s.state = 'tp1' then result_r_tp1only else rr end,
           result_r_partial = case when s.state = 'tp1' then round(0.5 * r1 + 0.5 * rr, 3) else rr end
     where id = p_id;
    insert into signal_updates(signal_id, created_by, kind, text)
      values (p_id, auth.uid(), 'close', coalesce(note || E'\n', '') || 'سكّروا الصفقة هلق. سعر الإغلاق تقريباً ' || round(px, dg)::text);
    return 'closed';
  end if;

  sl := coalesce(p_sl, s.stop_loss); t1 := coalesce(p_tp1, s.tp1); t2 := coalesce(p_tp2, s.tp2);
  if (buy and not (sl < t1)) or ((not buy) and not (sl > t1)) then raise exception 'الستوب والهدف 1 على جهات غلط'; end if;
  if s.state = 'waiting' and ((buy and not (sl < s.entry and s.entry < t1)) or ((not buy) and not (t1 < s.entry and s.entry < sl))) then
    raise exception 'الستوب أو الهدف 1 على الجهة الغلط من سعر الدخول';
  end if;
  if t2 is not null and ((buy and t2 < t1) or ((not buy) and t2 > t1)) then raise exception 'الهدف 2 لازم يكون أبعد من الهدف 1'; end if;
  if abs(sl - s.entry) > 0.2 * s.entry or abs(t1 - s.entry) > 0.2 * s.entry or (t2 is not null and abs(t2 - s.entry) > 0.2 * s.entry) then
    raise exception 'رقم غريب: بعيد أكتر من 20%% عن الدخول. تأكد من الفاصلة العشرية';
  end if;

  if sl is distinct from s.stop_loss then parts := parts || ('وقف الخسارة: ' || round(s.stop_loss, dg) || ' ← ' || round(sl, dg)); end if;
  if t1 is distinct from s.tp1 then parts := parts || ('الهدف 1: ' || round(s.tp1, dg) || ' ← ' || round(t1, dg)); end if;
  if t2 is distinct from s.tp2 then parts := parts || ('الهدف 2: ' || coalesce(round(s.tp2, dg)::text, '—') || ' ← ' || coalesce(round(t2, dg)::text, '—')); end if;
  if cardinality(parts) = 0 and note is null then raise exception 'ما في تغيير ولا تعليق'; end if;

  if cardinality(parts) > 0 then
    update signals set stop_loss = sl, tp1 = t1, tp2 = t2,
           orig_stop = case when s.state = 'waiting' then sl else orig_stop end,
           risk_usd_001 = case when s.state = 'waiting' then coalesce(risk_usd_001_of(symbol, entry, sl), risk_usd_001) else risk_usd_001 end
     where id = p_id;
  end if;
  insert into signal_updates(signal_id, created_by, kind, text)
    values (p_id, auth.uid(), case when cardinality(parts) > 0 then 'levels' else 'note' end,
            array_to_string(parts || coalesce(note, ''), E'\n'));
  return 'updated';
end $$;
revoke all on function public.staff_update_signal(bigint, numeric, numeric, numeric, text, boolean) from public, anon;
grant execute on function public.staff_update_signal(bigint, numeric, numeric, numeric, text, boolean) to authenticated;

-- notify room members about an update (channel: short, no levels)
create or replace function public.signal_update_notify() returns trigger
language plpgsql security definer set search_path = public as $$
declare s record; name text; dir text; url text := (select value #>> '{}' from app_config where key = 'site_url');
        head text; m record; users uuid[];
begin
  select * into s from signals where id = new.signal_id;
  if s.id is null or s.shadow then return new; end if;
  name := coalesce((select x->>'name' from jsonb_array_elements((select value from app_config where key = 'symbols')) x where x->>'code' = s.symbol), s.symbol);
  dir := case when s.side = 'BUY' then 'شراء' else 'بيع' end;
  head := case new.kind when 'close' then format('⏹ %s %s · قرار إغلاق', name, dir) else format('✏️ تحديث على %s (%s)', name, dir) end;
  perform telegram_send(head || E'\nالتفاصيل داخل غرفتك.' || coalesce(E'\n' || url, ''));
  for m in select p.telegram_chat_id from profiles p
           where p.telegram_chat_id is not null and p.ib_verified and p.room = any(s.rooms) loop
    perform telegram_dm(m.telegram_chat_id, head || E'\n' || new.text || coalesce(E'\n' || url || 'rooms', ''));
  end loop;
  select array_agg(p.id) into users from profiles p where p.ib_verified and p.room = any(s.rooms);
  perform push_send(users, head, new.text, '/rooms?room=' || (select min(x) from unnest(s.rooms) x)::text || '#s' || s.id, 'upd' || new.id);
  return new;
end $$;
drop trigger if exists signal_updates_notify on public.signal_updates;
create trigger signal_updates_notify after insert on public.signal_updates for each row execute function public.signal_update_notify();

-- the automatic "closed" messages must not claim "after 5 days" for a manual close (that one has its own update)
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
  elsif new.state is distinct from old.state and coalesce(new.closed_reason, '') <> 'manual' then
    msg := case new.state
      when 'open'    then format('⚡ %s %s · اتفعّلت الصفقة', name, dir)
      when 'tp1'     then format('✅ %s %s · تحقق الهدف 1 — انقل الستوب لنقطة الدخول', name, dir)
      when 'tp2'     then case when new.tp2 is null then format('✅ %s %s · تحقق الهدف', name, dir) else format('✅✅ %s %s · تحقق الهدف 2', name, dir) end
      when 'sl'      then case when new.stop_loss is distinct from new.orig_stop then format('❌ %s %s · ضربت وقف الخسارة المعدّل', name, dir) else format('❌ %s %s · ضربت وقف الخسارة', name, dir) end
      when 'be'      then case when new.tp1_at is null then format('↩️ %s %s · ضربت الستوب المعدّل (بدون خسارة)', name, dir) else format('↩️ %s %s · ضربت الستوب بعد الهدف 1 (ربح على نص الصفقة)', name, dir) end
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

-- same rule for the phone notifications of state changes
create or replace function public.signal_push() returns trigger
language plpgsql security definer set search_path = public as $$
declare name text := coalesce((select x->>'name' from jsonb_array_elements((select value from app_config where key = 'symbols')) x where x->>'code' = new.symbol), new.symbol);
        dir text := case when new.side = 'BUY' then 'شراء' else 'بيع' end;
        t text; b text; users uuid[]; r int := (select min(x) from unnest(new.rooms) x);
begin
  if tg_op = 'INSERT' then
    t := format('🔔 توصية جديدة · %s (%s)', name, dir);
    b := 'الدخول والستوب والأهداف وحجم اللوت المناسب لحسابك داخل غرفتك.';
  elsif new.state is distinct from old.state and coalesce(new.closed_reason, '') <> 'manual' then
    t := case new.state
      when 'open'    then format('⚡ %s %s · اتفعّلت الصفقة', name, dir)
      when 'tp1'     then format('✅ %s %s · تحقق الهدف 1', name, dir)
      when 'tp2'     then format('✅✅ %s %s · تحقق الهدف%s', name, dir, case when new.tp2 is null then '' else ' 2' end)
      when 'sl'      then format('❌ %s %s · ضربت وقف الخسارة', name, dir)
      when 'be'      then format('↩️ %s %s · ضربت الستوب بدون خسارة', name, dir)
      when 'expired' then format('⏹ %s %s · الأمر المعلّق انلغى', name, dir)
      when 'closed'  then format('⏹ %s %s · أُغلقت بعد 5 أيام', name, dir)
      else null end;
    b := case new.state when 'tp1' then 'انقل الستوب لنقطة الدخول. التفاصيل بالغرفة.' else 'التفاصيل بالغرفة.' end;
  end if;
  if t is null then return new; end if;
  select array_agg(p.id) into users from profiles p where p.ib_verified and p.room = any(new.rooms);
  perform push_send(users, t, b, '/rooms?room=' || coalesce(r, 1)::text || '#s' || new.id, 'sig' || new.id);
  return new;
end $$;
