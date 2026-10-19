-- 015: promote a strong community member's idea to the expert rooms.
-- Eligible: pending (not yet triggered) ideas from members with >= 20 closed ideas and a positive average R.
-- The manager clicks "promote": the idea goes through the same rule check as an analyst signal and lands in the
-- pending list; after approval it is published crediting "@username" (never the real name).

alter table public.suggestions drop constraint if exists suggestions_source_check;
alter table public.suggestions add constraint suggestions_source_check check (source in ('engine','analyst','community'));
alter table public.suggestions add column if not exists credit_username text;
alter table public.suggestions add column if not exists community_trade_id bigint references public.community_trades(id);
alter table public.signals add column if not exists credit_username text;

create or replace function public.community_candidates(p_min_trades int default 20)
returns table (id bigint, username text, trades int, win_rate numeric, avg_r numeric, total_r numeric,
               symbol text, side text, order_type text, entry numeric, stop_loss numeric, take_profit numeric,
               posted_at timestamptz, expires_at timestamptz, note text, promoted boolean)
language sql stable security definer set search_path = public as $$
  with st as (
    select user_id, count(*)::int n, round(100.0 * count(*) filter (where result_r > 0) / count(*), 1) wr,
           round(avg(result_r), 3) ar, round(sum(result_r), 2) tr
    from community_trades where result_r is not null group by user_id)
  select c.id, p.username, st.n, st.wr, st.ar, st.tr, c.symbol, c.side, c.order_type, c.entry, c.stop_loss, c.take_profit,
         c.posted_at, c.expires_at, c.note,
         exists (select 1 from suggestions s where s.community_trade_id = c.id)
  from community_trades c join st on st.user_id = c.user_id join profiles p on p.id = c.user_id
  where coalesce(my_role(), 'client') in ('analyst','manager','admin')
    and c.state = 'waiting' and st.n >= p_min_trades and st.ar > 0
  order by st.ar desc, c.posted_at desc;
$$;
revoke all on function public.community_candidates(int) from public, anon;
grant execute on function public.community_candidates(int) to authenticated;

create or replace function public.promote_community(p_id bigint)
returns bigint language plpgsql security definer set search_path = public as $$
declare c record; uname text; new_id bigint; hrs int;
begin
  if coalesce(my_role(), 'client') not in ('manager','admin') then raise exception 'not allowed'; end if;
  select * into c from community_trades where id = p_id;
  if c.id is null or c.state <> 'waiting' then raise exception 'الفكرة مش متاحة (اتفعّلت أو انتهت)'; end if;
  if exists (select 1 from suggestions where community_trade_id = p_id) then raise exception 'انرشّحت قبل'; end if;
  select username into uname from profiles where id = c.user_id;
  hrs := greatest(1, ceil(extract(epoch from (coalesce(c.expires_at, now() + interval '12 hours') - now())) / 3600)::int);
  new_id := analyst_submit_signal(c.symbol, c.side, c.order_type, c.entry, c.stop_loss, c.take_profit, null, hrs,
                                  'فكرة من العضو @' || uname);
  update suggestions set source = 'community', credit_username = uname, community_trade_id = p_id where id = new_id;
  return new_id;
end $$;
revoke all on function public.promote_community(bigint) from public, anon;
grant execute on function public.promote_community(bigint) to authenticated;

-- Telegram: mention the member on new signals that came from the community
create or replace function public.signal_notify() returns trigger
language plpgsql security definer set search_path = public as $$
declare name text := coalesce((select x->>'name' from jsonb_array_elements((select value from app_config where key = 'symbols')) x where x->>'code' = new.symbol), new.symbol);
        dir  text := case when new.side = 'BUY' then 'شراء' else 'بيع' end;
        url  text := (select value #>> '{}' from app_config where key = 'site_url');
        msg  text;
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
  end if;
  return new;
end $$;
