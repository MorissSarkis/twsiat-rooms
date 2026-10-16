-- 010: more instruments for the levels page and the community room (prices only).
-- Expert signals stay gold-only until each instrument passes its own backtest.
-- The MT5 bridge must send these symbols (SymbolMap on the server).

-- Only symbols that actually have recent prices are offered to clients.
update public.app_config set value = '[
 {"code":"XAUUSD","name":"الذهب","group":"معادن","digits":2},
 {"code":"XAGUSD","name":"الفضة","group":"معادن","digits":3},
 {"code":"USOIL","name":"نفط WTI","group":"طاقة","digits":2},
 {"code":"UKOIL","name":"نفط برنت","group":"طاقة","digits":2},
 {"code":"XNGUSD","name":"الغاز الطبيعي","group":"طاقة","digits":3},
 {"code":"US30","name":"داو جونز","group":"مؤشرات","digits":1},
 {"code":"USTEC","name":"ناسداك 100","group":"مؤشرات","digits":1},
 {"code":"US500","name":"S&P 500","group":"مؤشرات","digits":1},
 {"code":"DE30","name":"داكس","group":"مؤشرات","digits":1},
 {"code":"UK100","name":"فوتسي 100","group":"مؤشرات","digits":1},
 {"code":"JP225","name":"نيكاي 225","group":"مؤشرات","digits":0},
 {"code":"EURUSD","name":"يورو / دولار","group":"عملات","digits":5},
 {"code":"GBPUSD","name":"باوند / دولار","group":"عملات","digits":5},
 {"code":"USDJPY","name":"دولار / ين","group":"عملات","digits":3},
 {"code":"USDCHF","name":"دولار / فرنك","group":"عملات","digits":5},
 {"code":"AUDUSD","name":"أسترالي / دولار","group":"عملات","digits":5},
 {"code":"USDCAD","name":"دولار / كندي","group":"عملات","digits":5},
 {"code":"NZDUSD","name":"نيوزلندي / دولار","group":"عملات","digits":5},
 {"code":"BTCUSD","name":"بيتكوين","group":"كريبتو","digits":2},
 {"code":"ETHUSD","name":"إيثيريوم","group":"كريبتو","digits":2}
]'::jsonb where key = 'symbols';

create or replace function public.list_symbols() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(s order by ord), '[]'::jsonb)
  from jsonb_array_elements((select value from app_config where key = 'symbols')) with ordinality as x(s, ord)
  where exists (select 1 from prices_m5 p where p.symbol = s->>'code' and p.t > now() - interval '10 days');
$$;
revoke all on function public.list_symbols() from public, anon;
grant execute on function public.list_symbols() to authenticated;

-- error messages show prices with the right number of decimals for each instrument
create or replace function public.community_post(
  p_symbol text, p_side text, p_order_type text,
  p_entry numeric, p_stop numeric, p_tp numeric, p_note text default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare
  cfg jsonb := (select value from app_config where key = 'community');
  me record; last record; ctx record; buy boolean := p_side = 'BUY';
  bid numeric; ask numeric; e numeric; risk numeric; new_id bigint;
begin
  select * into me from profiles where id = auth.uid();
  if me.id is null or not me.ib_verified then raise exception 'حسابك لازم يكون مفعّل لتنشر بالغرفة'; end if;
  if me.username is null then raise exception 'اختار اسم مستخدم أول'; end if;
  if p_side not in ('BUY','SELL') then raise exception 'اتجاه غير صحيح'; end if;
  if p_order_type not in ('MARKET','BUY_LIMIT','SELL_LIMIT','BUY_STOP','SELL_STOP')
     or (p_order_type <> 'MARKET' and split_part(p_order_type, '_', 1) <> p_side) then
    raise exception 'نوع الأمر لا يطابق الاتجاه';
  end if;
  if not exists (select 1 from jsonb_array_elements(list_symbols()) s where s->>'code' = p_symbol) then
    raise exception 'الأصل غير متاح';
  end if;
  if (select count(*) from community_trades where user_id = me.id and state in ('waiting','open')) >= (cfg->>'max_open')::int then
    raise exception 'عندك % أفكار مفتوحة، استنى لتسكّر وحدة', cfg->>'max_open';
  end if;
  if (select count(*) from community_trades where user_id = me.id and posted_at > now() - interval '1 day') >= (cfg->>'max_per_day')::int then
    raise exception 'وصلت للحد اليومي (%)', cfg->>'max_per_day';
  end if;

  select * into last from prices_m5 where symbol = p_symbol order by t desc limit 1;
  if last.t is null then raise exception 'ما في أسعار لهالأصل'; end if;
  bid := last.close; ask := last.close + coalesce(last.spread, 0);

  if p_order_type = 'MARKET' then
    if last.t < now() - interval '15 minutes' then raise exception 'السوق مسكّر هلق، استعمل أمر معلق'; end if;
    e := case when buy then ask else bid end;       -- the server sets the price, not the client
  else
    e := p_entry;
    if e is null then raise exception 'حط سعر الدخول'; end if;
    if (p_order_type = 'BUY_LIMIT'  and e >= ask) or (p_order_type = 'BUY_STOP'  and e <= ask)
    or (p_order_type = 'SELL_LIMIT' and e <= bid) or (p_order_type = 'SELL_STOP' and e >= bid) then
      raise exception 'سعر الدخول ما بيناسب نوع الأمر (السعر الحالي %)', trim_scale(round(bid, 5));
    end if;
  end if;

  if buy and not (p_stop < e and e < p_tp) then raise exception 'للشراء: الستوب تحت الدخول والهدف فوقه'; end if;
  if (not buy) and not (p_tp < e and e < p_stop) then raise exception 'للبيع: الهدف تحت الدخول والستوب فوقه'; end if;

  risk := abs(e - p_stop);
  select * into ctx from engine_context(p_symbol, (now() at time zone 'UTC')::date);
  if ctx.atr is not null and (risk < (cfg->>'min_sl_atr')::numeric * ctx.atr or risk > (cfg->>'max_sl_atr')::numeric * ctx.atr) then
    raise exception 'مسافة الستوب غير منطقية لهالأصل (المدى اليومي تقريباً %)', trim_scale(round(ctx.atr, 5));
  end if;

  insert into community_trades (user_id, symbol, side, order_type, entry, stop_loss, take_profit,
                                posted_at, expires_at, state, filled_at, posted_price, last_bar_t, note)
  values (me.id, p_symbol, p_side, p_order_type, e, p_stop, p_tp, now(),
          case when p_order_type = 'MARKET' then null else now() + make_interval(hours => (cfg->>'pending_hours')::int) end,
          case when p_order_type = 'MARKET' then 'open' else 'waiting' end,
          case when p_order_type = 'MARKET' then last.t end,   -- entry = close of this bar; later bars count fully
          bid, last.t, nullif(left(trim(p_note), 280), ''))
  returning id into new_id;
  return new_id;
end $$;
revoke all on function public.community_post(text,text,text,numeric,numeric,numeric,text) from public, anon;
grant execute on function public.community_post(text,text,text,numeric,numeric,numeric,text) to authenticated;

-- keep about 14 months of M5 bars (enough for every indicator); runs daily at 03:30 GMT
create or replace function public.prices_cleanup() returns void
language sql security definer set search_path = public as $$
  delete from prices_m5 where t < now() - interval '420 days';
$$;
revoke all on function public.prices_cleanup() from public, anon, authenticated;
select cron.schedule('prices-cleanup', '30 3 * * *', 'select public.prices_cleanup()');
