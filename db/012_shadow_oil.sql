-- 012: shadow mode (paper trading) for oil.
-- Rule found in testing (Jan 2020 – Oct 2026, M5, spread included):
--   trade USOIL only when oil's own daily + H1 trend point one way AND gold's daily + H1 trend point the other way;
--   entry, stop, targets and expiry exactly as the gold engine.
--   196 trades (~29/yr), 55.6% win, +0.137R (half/BE/TP2), 2020–23 +0.143, 2024–26 +0.129, max DD 10.2R.
--   Found after trying 8 variants, so it may be partly luck: it runs in the shadow for 2–3 months before clients see it.
-- Shadow signals: rooms = '{}' (no client can read them), shadow = true, no Telegram, tracked like real signals.

alter table public.signals add column if not exists shadow boolean not null default false;

insert into public.app_config values
  ('shadow_rules', '[{"symbol":"USOIL","ref":"XAUUSD","ref_sign":-1}]'),
  ('hist_USOIL_shadow', '{"win_rate":55.6,"avg_r":0.137,"sample":196}')
on conflict (key) do update set value = excluded.value;
-- $ per 1.0 price move for 0.01 lot. USOIL at Exness: 1 lot = 1,000 barrels (check the contract spec before going live).
update public.app_config set value = value || '{"USOIL":10}'::jsonb where key = 'usd_per_point_001';

create or replace function public.engine_shadow(p_symbol text, p_ref text, p_ref_sign int, p_now timestamptz default now())
returns bigint language plpgsql security definer set search_path = public as $$
declare
  cfg jsonb := (select value from app_config where key = 'rules');
  d date := (p_now at time zone 'UTC')::date;
  day_start timestamptz := d::timestamp at time zone 'UTC';
  dg int := coalesce((select (x->>'digits')::int from jsonb_array_elements((select value from app_config where key = 'symbols')) x where x->>'code' = p_symbol), 2);
  usd numeric := coalesce(((select value from app_config where key = 'usd_per_point_001')->>p_symbol)::numeric, 1);
  tag text := 'shadow ' || p_symbol;
  ft timestamptz; fo numeric; rt timestamptz; c record; r record; ref_up boolean; buy boolean; h1 boolean;
  e numeric; sld numeric; s int; new_id bigint;
begin
  if exists (select 1 from signals where shadow and symbol = p_symbol and published_at >= day_start and published_at < day_start + interval '1 day')
     or exists (select 1 from engine_log where symbol = p_symbol and msg like tag || ': no setup%' and t >= day_start and t < day_start + interval '1 day') then
    return null;
  end if;
  select t, open into ft, fo from prices_m5 where symbol = p_symbol and t >= day_start and t < day_start + interval '1 day' and t <= p_now order by t limit 1;
  select t into rt from prices_m5 where symbol = p_ref and t >= day_start and t < day_start + interval '1 day' and t <= p_now order by t limit 1;
  if ft is null or rt is null then return null; end if;     -- wait until both markets have opened today

  select * into r from engine_context(p_ref, d);
  select * into c from engine_context(p_symbol, d);
  if r.atr is null or c.atr is null or r.n_days < (cfg->>'sma_days')::int or c.n_days < (cfg->>'sma_days')::int then
    insert into engine_log(t, symbol, msg) values (p_now, p_symbol, tag || ': no setup: not enough history'); return null;
  end if;
  ref_up := r.prev_close > r.sma;
  if engine_h1_up(p_ref, rt) is distinct from ref_up then
    insert into engine_log(t, symbol, msg) values (p_now, p_symbol, tag || ': no setup: ' || p_ref || ' daily and H1 disagree'); return null;
  end if;
  buy := case when p_ref_sign > 0 then ref_up else not ref_up end;
  if (c.prev_close > c.sma) is distinct from buy then
    insert into engine_log(t, symbol, msg) values (p_now, p_symbol, tag || ': no setup: daily trend disagrees with ' || p_ref); return null;
  end if;
  if (buy and fo <= c.p) or ((not buy) and fo >= c.p) then
    insert into engine_log(t, symbol, msg) values (p_now, p_symbol, tag || ': no setup: day opened beyond the pivot'); return null;
  end if;
  h1 := engine_h1_up(p_symbol, ft);
  if h1 is distinct from buy then
    insert into engine_log(t, symbol, msg) values (p_now, p_symbol, tag || ': no setup: H1 trend disagrees'); return null;
  end if;

  sld := (cfg->>'sl_atr')::numeric * c.atr; s := case when buy then 1 else -1 end; e := round(c.p, dg);
  insert into signals (rooms, symbol, side, order_type, entry, stop_loss, tp1, tp2, risk_usd_001, published_at, expires_at, shadow)
  values ('{}', p_symbol, case when buy then 'BUY' else 'SELL' end, case when buy then 'BUY_LIMIT' else 'SELL_LIMIT' end,
          e, round(c.p - s * sld, dg), round(c.p + s * (cfg->>'tp1_r')::numeric * sld, dg), round(c.p + s * (cfg->>'tp2_r')::numeric * sld, dg),
          round(sld * usd, 2), ft, day_start + make_interval(hours => (cfg->>'expiry_hour')::int), true)
  returning id into new_id;
  insert into engine_log(t, symbol, msg, data) values (p_now, p_symbol, tag || ': signal created', jsonb_build_object('id', new_id));
  return new_id;
end $$;
revoke all on function public.engine_shadow(text, text, int, timestamptz) from public, anon, authenticated;

create or replace function public.engine_tick()
returns void language plpgsql security definer set search_path = public as $$
declare sym text; sh jsonb;
begin
  for sym in select jsonb_array_elements_text(value) from app_config where key = 'engine_symbols' loop
    perform engine_make_suggestion(sym);
  end loop;
  for sh in select jsonb_array_elements(value) from app_config where key = 'shadow_rules' loop
    perform engine_shadow(sh->>'symbol', sh->>'ref', (sh->>'ref_sign')::int);
  end loop;
  perform engine_track();
  perform community_track();
  perform engine_expire_suggestions();
end $$;
revoke all on function public.engine_tick() from public, anon, authenticated;

-- no Telegram for shadow signals
drop trigger if exists signals_notify on public.signals;
create trigger signals_notify after insert or update of state on public.signals
  for each row when (not new.shadow) execute function public.signal_notify();

-- oil prices have 3 decimals at Exness
update public.app_config
   set value = (select jsonb_agg(case when x->>'code' in ('USOIL','UKOIL') then x || '{"digits":3}'::jsonb else x end order by o)
                from jsonb_array_elements(value) with ordinality as t(x, o))
 where key = 'symbols';

-- back office: live shadow results next to the backtest expectation
create or replace function public.shadow_stats()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare out jsonb := '[]'; sh jsonb; sym text;
begin
  if coalesce(my_role(), 'client') not in ('analyst','manager','admin') then raise exception 'not allowed'; end if;
  for sh in select jsonb_array_elements(value) from app_config where key = 'shadow_rules' loop
    sym := sh->>'symbol';
    out := out || jsonb_build_object(
      'symbol', sym, 'ref', sh->>'ref',
      'expected', (select value from app_config where key = 'hist_' || sym || '_shadow'),
      'live', (select jsonb_build_object(
                 'signals', count(*),
                 'closed', count(*) filter (where result_r_partial is not null),
                 'win_rate', round(100.0 * count(*) filter (where result_r_partial > 0) / nullif(count(*) filter (where result_r_partial is not null), 0), 1),
                 'avg_r', round(avg(result_r_partial), 3),
                 'total_r', round(coalesce(sum(result_r_partial), 0), 2))
               from signals where shadow and symbol = sym),
      'recent', (select coalesce(jsonb_agg(x order by x.published_at desc), '[]') from (
                   select id, side, entry, stop_loss, tp1, tp2, state, published_at, result_r_partial
                   from signals where shadow and symbol = sym order by published_at desc limit 10) x));
  end loop;
  return out;
end $$;
revoke all on function public.shadow_stats() from public, anon;
grant execute on function public.shadow_stats() to authenticated;
