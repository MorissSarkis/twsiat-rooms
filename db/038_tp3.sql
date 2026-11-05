-- 038: optional third target (TP3) on signals.
--  * Without TP3 nothing changes: half at TP1, stop to entry, half at TP2.
--  * With TP3 the trade is split in thirds: a third at TP1 (stop → entry), a third at TP2 (stop → TP1),
--    the last third at TP3 or at the protected stop. Members get "✅✅✅ تحقق الهدف 3".
--  * Staff can set/change TP3 when publishing and in "update a live signal"; a trade at TP2 waiting for TP3
--    can still be updated or closed by hand.
-- Requires 033, 036. Safe to run more than once.

alter table public.signals     add column if not exists tp3 numeric;
alter table public.signals     add column if not exists tp2_at timestamptz;
alter table public.suggestions add column if not exists tp3 numeric;
alter table public.signals drop constraint if exists signals_state_check;
alter table public.signals add constraint signals_state_check
  check (state in ('waiting','open','tp1','tp2','tp3','sl','be','expired','closed'));

create or replace function public.signal_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare buy boolean := new.side = 'BUY';
begin
  if new.entry is null or new.stop_loss is null or new.tp1 is null then raise exception 'ناقص: الدخول والستوب والهدف 1'; end if;
  if (buy and not (new.stop_loss < new.entry and new.entry < new.tp1))
     or (not buy and not (new.tp1 < new.entry and new.entry < new.stop_loss)) then
    raise exception 'الستوب أو الهدف 1 على الجهة الغلط من سعر الدخول';
  end if;
  if new.tp2 is not null and ((buy and new.tp2 < new.tp1) or (not buy and new.tp2 > new.tp1)) then
    raise exception 'الهدف 2 لازم يكون أبعد من الهدف 1';
  end if;
  if new.tp3 is not null and (new.tp2 is null or (buy and new.tp3 <= new.tp2) or (not buy and new.tp3 >= new.tp2)) then
    raise exception 'الهدف 3 لازم يكون أبعد من الهدف 2 (ولازم يكون في هدف 2)';
  end if;
  if new.tp3 is not null and abs(new.tp3 - new.entry) > 0.2 * new.entry then
    raise exception 'رقم غريب: الهدف 3 بعيد أكتر من 20%% عن الدخول. تأكد من الفاصلة العشرية';
  end if;
  if abs(new.tp1 - new.entry) > 0.2 * new.entry or abs(new.stop_loss - new.entry) > 0.2 * new.entry
     or (new.tp2 is not null and abs(new.tp2 - new.entry) > 0.2 * new.entry) then
    raise exception 'رقم غريب: هدف أو ستوب بعيد أكتر من 20%% عن الدخول. تأكد من الفاصلة العشرية';
  end if;
  new.risk_usd_001 := risk_usd_001_of(new.symbol, new.entry, new.stop_loss);
  return new;
end $$;


create or replace function public.engine_track(p_now timestamptz default now())
returns integer language plpgsql security definer set search_path = public as $$
declare
  sig record; b record; buy boolean; stop numeric; risk numeric; r1 numeric; r2 numeric; r3 numeric; rs numeric; rc numeric;
  lo numeric; hi numeric; hold interval; n int := 0; done boolean; thirds boolean;
begin
  hold := make_interval(days => ((select value from app_config where key = 'rules')->>'max_hold_days')::int);
  for sig in select * from signals
             where state in ('waiting','open','tp1') or (state = 'tp2' and closed_at is null) order by id loop
    buy := sig.side = 'BUY';
    risk := abs(sig.entry - coalesce(sig.orig_stop, sig.stop_loss));
    if risk = 0 then continue; end if;
    r1 := abs(sig.tp1 - sig.entry) / risk;
    r2 := case when sig.tp2 is null then null else abs(sig.tp2 - sig.entry) / risk end;
    r3 := case when sig.tp3 is null or sig.tp2 is null then null else abs(sig.tp3 - sig.entry) / risk end;
    thirds := r3 is not null;          -- with TP3: a third at each target; without: half at TP1, half at TP2
    -- after TP1 the stop is at least at the entry, after TP2 at least at TP1; staff may have moved it further
    stop := case when sig.state = 'tp1' then case when buy then greatest(sig.entry, sig.stop_loss) else least(sig.entry, sig.stop_loss) end
                 when sig.state = 'tp2' then case when buy then greatest(sig.tp1, sig.stop_loss) else least(sig.tp1, sig.stop_loss) end
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
        rc := (case when buy then b.close - sig.entry else sig.entry - b.close end) / risk;
        if sig.state = 'tp2' then
          sig.result_r_partial := round((r1 + r2 + rc) / 3, 3);         -- state stays tp2 (TP2 reached)
        elsif sig.state = 'tp1' then
          sig.result_r_partial := round(case when thirds then r1 / 3 + 2 * rc / 3 else 0.5 * r1 + 0.5 * rc end, 3);
          sig.state := 'closed';
        else
          sig.result_r_tp1only := round(rc, 3); sig.result_r_partial := sig.result_r_tp1only; sig.state := 'closed';
        end if;
        sig.closed_reason := 'time'; sig.closed_at := b.t; done := true; exit;
      end if;

      if (buy and lo <= stop) or ((not buy) and hi >= stop) then
        rs := (case when buy then stop - sig.entry else sig.entry - stop end) / risk;
        if sig.state = 'tp2' then
          sig.result_r_partial := round((r1 + r2 + rs) / 3, 3);         -- state stays tp2 (TP2 reached)
        elsif sig.state = 'tp1' then
          sig.state := 'be';
          sig.result_r_partial := round(case when thirds then r1 / 3 + 2 * rs / 3 else 0.5 * r1 + 0.5 * rs end, 3);
        else
          sig.state := case when rs < 0 then 'sl' else 'be' end;
          sig.result_r_tp1only := round(rs, 3); sig.result_r_partial := round(rs, 3);
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
          sig.state := 'tp2'; sig.tp2_at := b.t;
          if not thirds then
            sig.result_r_partial := round(0.5 * r1 + 0.5 * r2, 3); sig.closed_at := b.t; done := true; exit;
          end if;
          stop := case when buy then greatest(sig.tp1, sig.stop_loss) else least(sig.tp1, sig.stop_loss) end;
          sig.stop_moved_to := stop;
        end if;
        if sig.state = 'tp2' and thirds and ((buy and hi >= sig.tp3) or ((not buy) and lo <= sig.tp3)) then
          sig.state := 'tp3'; sig.result_r_partial := round((r1 + r2 + r3) / 3, 3);
          sig.closed_at := b.t; done := true; exit;
        end if;
      end if;
    end loop;

    update signals set state = sig.state, filled_at = sig.filled_at, tp1_at = sig.tp1_at, tp2_at = sig.tp2_at, closed_at = sig.closed_at,
           result_r_tp1only = sig.result_r_tp1only, result_r_partial = sig.result_r_partial,
           stop_moved_to = sig.stop_moved_to, last_bar_t = sig.last_bar_t, closed_reason = sig.closed_reason
     where id = sig.id;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.engine_track(timestamptz) from public, anon, authenticated;

drop function if exists public.staff_update_signal(bigint, numeric, numeric, numeric, text, boolean);
create or replace function public.staff_update_signal(p_id bigint, p_sl numeric, p_tp1 numeric, p_tp2 numeric, p_tp3 numeric,
                                                      p_note text, p_close boolean default false)
returns text language plpgsql security definer set search_path = public as $$
declare s record; buy boolean; sl numeric; t1 numeric; t2 numeric; t3 numeric; r2 numeric; thirds boolean; parts text[] := '{}'; dg int; risk numeric;
        px numeric; rr numeric; r1 numeric; note text := nullif(trim(coalesce(p_note, '')), '');
begin
  if coalesce(my_role(), '') not in ('manager','admin') then raise exception 'not allowed'; end if;
  select * into s from signals where id = p_id for update;
  if s.id is null or s.shadow then raise exception 'التوصية مش موجودة'; end if;
  if not (s.state in ('waiting','open','tp1') or (s.state = 'tp2' and s.closed_at is null)) then raise exception 'التوصية مسكّرة، ما بتنعدّل'; end if;
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
    r2 := case when s.tp2 is null then null else abs(s.tp2 - s.entry) / risk end;
    thirds := s.tp3 is not null;
    if s.state = 'tp2' then   -- only with TP3: TP1 and TP2 already taken, last third closed now
      update signals set closed_reason = 'manual', closed_at = now(),
             result_r_partial = round((r1 + r2 + rr) / 3, 3)
       where id = p_id;
    else
      update signals set state = 'closed', closed_reason = 'manual', closed_at = now(),
             result_r_tp1only = case when s.state = 'tp1' then result_r_tp1only else rr end,
             result_r_partial = case when s.state <> 'tp1' then rr
                                     when thirds then round(r1 / 3 + 2 * rr / 3, 3)
                                     else round(0.5 * r1 + 0.5 * rr, 3) end
       where id = p_id;
    end if;
    insert into signal_updates(signal_id, created_by, kind, text)
      values (p_id, auth.uid(), 'close', coalesce(note || E'\n', '') || 'سكّروا الصفقة هلق. سعر الإغلاق تقريباً ' || round(px, dg)::text);
    return 'closed';
  end if;

  sl := coalesce(p_sl, s.stop_loss); t1 := coalesce(p_tp1, s.tp1); t2 := coalesce(p_tp2, s.tp2); t3 := coalesce(p_tp3, s.tp3);
  if (buy and not (sl < t1)) or ((not buy) and not (sl > t1)) then raise exception 'الستوب والهدف 1 على جهات غلط'; end if;
  if s.state = 'waiting' and ((buy and not (sl < s.entry and s.entry < t1)) or ((not buy) and not (t1 < s.entry and s.entry < sl))) then
    raise exception 'الستوب أو الهدف 1 على الجهة الغلط من سعر الدخول';
  end if;
  if t2 is not null and ((buy and t2 < t1) or ((not buy) and t2 > t1)) then raise exception 'الهدف 2 لازم يكون أبعد من الهدف 1'; end if;
  if t3 is not null and (t2 is null or (buy and t3 <= t2) or ((not buy) and t3 >= t2)) then raise exception 'الهدف 3 لازم يكون أبعد من الهدف 2'; end if;
  if t3 is not null and abs(t3 - s.entry) > 0.2 * s.entry then raise exception 'رقم غريب: الهدف 3 بعيد أكتر من 20%% عن الدخول'; end if;
  if abs(sl - s.entry) > 0.2 * s.entry or abs(t1 - s.entry) > 0.2 * s.entry or (t2 is not null and abs(t2 - s.entry) > 0.2 * s.entry) then
    raise exception 'رقم غريب: بعيد أكتر من 20%% عن الدخول. تأكد من الفاصلة العشرية';
  end if;

  if sl is distinct from s.stop_loss then parts := parts || ('وقف الخسارة: ' || round(s.stop_loss, dg) || ' ← ' || round(sl, dg)); end if;
  if t1 is distinct from s.tp1 then parts := parts || ('الهدف 1: ' || round(s.tp1, dg) || ' ← ' || round(t1, dg)); end if;
  if t2 is distinct from s.tp2 then parts := parts || ('الهدف 2: ' || coalesce(round(s.tp2, dg)::text, '—') || ' ← ' || coalesce(round(t2, dg)::text, '—')); end if;
  if t3 is distinct from s.tp3 then parts := parts || ('الهدف 3: ' || coalesce(round(s.tp3, dg)::text, '—') || ' ← ' || coalesce(round(t3, dg)::text, '—')); end if;
  if cardinality(parts) = 0 and note is null then raise exception 'ما في تغيير ولا تعليق'; end if;

  if cardinality(parts) > 0 then
    update signals set stop_loss = sl, tp1 = t1, tp2 = t2, tp3 = t3,
           orig_stop = case when s.state = 'waiting' then sl else orig_stop end,
           risk_usd_001 = case when s.state = 'waiting' then coalesce(risk_usd_001_of(symbol, entry, sl), risk_usd_001) else risk_usd_001 end
     where id = p_id;
  end if;
  insert into signal_updates(signal_id, created_by, kind, text)
    values (p_id, auth.uid(), case when cardinality(parts) > 0 then 'levels' else 'note' end,
            array_to_string(parts || coalesce(note, ''), E'\n'));
  return 'updated';
end $$;

revoke all on function public.staff_update_signal(bigint, numeric, numeric, numeric, numeric, text, boolean) from public, anon;
grant execute on function public.staff_update_signal(bigint, numeric, numeric, numeric, numeric, text, boolean) to authenticated;

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
        and (new.tp1_at is null or new.state in ('tp1', 'tp2', 'tp3')) then
    msg := case new.state
      when 'open'    then format('⚡ %s %s · اتفعّلت الصفقة', name, dir)
      when 'tp1'     then format('✅ %s %s · تحقق الهدف 1', name, dir)
      when 'tp2'     then case when new.tp2 is null then format('✅ %s %s · تحقق الهدف', name, dir) else format('✅✅ %s %s · تحقق الهدف 2', name, dir) end
      when 'tp3'     then format('✅✅✅ %s %s · تحقق الهدف 3', name, dir)
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
        and (new.tp1_at is null or new.state in ('tp1', 'tp2', 'tp3')) then
    t := case new.state
      when 'open'    then format('⚡ %s %s · اتفعّلت الصفقة', name, dir)
      when 'tp1'     then format('✅ %s %s · تحقق الهدف 1', name, dir)
      when 'tp2'     then format('✅✅ %s %s · تحقق الهدف%s', name, dir, case when new.tp2 is null then '' else ' 2' end)
      when 'tp3'     then format('✅✅✅ %s %s · تحقق الهدف 3', name, dir)
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

create or replace function public.track_record(p_limit int default 100)
returns jsonb language sql stable security definer set search_path = public as $$
  with s as (
    select * from signals where not shadow
  ), closed as (
    select * from s where closed_at is not null and state <> 'expired'
  )
  select jsonb_build_object(
    'summary', (select coalesce(jsonb_agg(x order by x.symbol), '[]') from (
        select symbol,
               count(*) as trades,
               count(*) filter (where result_r_partial > 0) as wins,
               round(100.0 * count(*) filter (where result_r_partial > 0) / nullif(count(*), 0), 1) as win_rate,
               round(coalesce(sum(result_r_partial), 0), 2) as total_r_partial,
               round(coalesce(sum(result_r_tp1only), 0), 2) as total_r_tp1only,
               round(avg(result_r_partial), 3) as avg_r_partial,
               min(published_at) as since
        from closed group by symbol) x),
    'open_now', (select count(*) from s where closed_at is null),
    'not_triggered', (select count(*) from s where state = 'expired'),
    'trades', (select coalesce(jsonb_agg(t order by t.closed_at desc), '[]') from (
        select id, symbol, side, order_type, entry, stop_loss, tp1, tp2, tp3, state,
               published_at, filled_at, tp1_at, tp2_at, closed_at, result_r_tp1only, result_r_partial
        from closed order by closed_at desc limit least(greatest(p_limit, 1), 500)) t)
  );
$$;
revoke all on function public.track_record(int) from public;
grant execute on function public.track_record(int) to anon, authenticated;

create or replace function public.room_teaser(p_room int) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'last30', (select count(*) from signals where not shadow and p_room = any(rooms) and published_at > now() - interval '30 days'),
    'closed', (select count(*) from signals where not shadow and p_room = any(rooms) and closed_at is not null and state <> 'expired'),
    'wins',   (select count(*) from signals where not shadow and p_room = any(rooms) and closed_at is not null and state <> 'expired' and result_r_partial > 0))
  where auth.uid() is not null;
$$;
revoke all on function public.room_teaser(int) from public, anon;
grant execute on function public.room_teaser(int) to authenticated;
