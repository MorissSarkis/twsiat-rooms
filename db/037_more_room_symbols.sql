-- 037: 17 more instruments in the trading rooms (prices already come from the MT5 bridge for the alerts app):
--   currency crosses EURJPY EURCAD EURCHF EURGBP GBPJPY GBPCAD GBPAUD GBPCHF AUDJPY AUDCAD AUDCHF,
--   crypto XRPUSD UNIUSD, US stocks MSFT AMD AMZN NFLX.
-- Risk per 0.01 lot for any currency pair is now worked out from the live rate of its quote currency,
-- so crosses get a correct lot size. Stocks, XRP and UNI: contract size differs by broker → no lot size shown
-- (same as indices), the signal still publishes normally.
-- Safe to run more than once.

update public.app_config c
   set value = (select coalesce(jsonb_agg(x order by o), '[]'::jsonb)
                  from jsonb_array_elements(c.value) with ordinality t(x, o)
                 where x->>'code' not in ('EURJPY','EURCAD','EURCHF','EURGBP','GBPJPY','GBPCAD','GBPAUD','GBPCHF',
                                          'AUDJPY','AUDCAD','AUDCHF','XRPUSD','UNIUSD','MSFT','AMD','AMZN','NFLX'))
            || '[
 {"code":"EURGBP","name":"يورو / باوند","group":"عملات","digits":5},
 {"code":"EURJPY","name":"يورو / ين","group":"عملات","digits":3},
 {"code":"EURCHF","name":"يورو / فرنك","group":"عملات","digits":5},
 {"code":"EURCAD","name":"يورو / كندي","group":"عملات","digits":5},
 {"code":"GBPJPY","name":"باوند / ين","group":"عملات","digits":3},
 {"code":"GBPCHF","name":"باوند / فرنك","group":"عملات","digits":5},
 {"code":"GBPCAD","name":"باوند / كندي","group":"عملات","digits":5},
 {"code":"GBPAUD","name":"باوند / أسترالي","group":"عملات","digits":5},
 {"code":"AUDJPY","name":"أسترالي / ين","group":"عملات","digits":3},
 {"code":"AUDCHF","name":"أسترالي / فرنك","group":"عملات","digits":5},
 {"code":"AUDCAD","name":"أسترالي / كندي","group":"عملات","digits":5},
 {"code":"XRPUSD","name":"ريبل XRP","group":"كريبتو","digits":4},
 {"code":"UNIUSD","name":"يونيسواب","group":"كريبتو","digits":3},
 {"code":"MSFT","name":"مايكروسوفت","group":"أسهم","digits":2},
 {"code":"AMD","name":"AMD","group":"أسهم","digits":2},
 {"code":"AMZN","name":"أمازون","group":"أسهم","digits":2},
 {"code":"NFLX","name":"نتفليكس","group":"أسهم","digits":2}
]'::jsonb
 where key = 'symbols';

-- $ risk for 0.01 lot. 0.01 lot of a currency pair = 1,000 units of the base currency; the move is paid in the
-- quote currency, converted to dollars with the latest price of that currency against the dollar.
create or replace function public.risk_usd_001_of(p_symbol text, p_entry numeric, p_stop numeric) returns numeric
language plpgsql stable security definer set search_path = public as $$
declare fx text[] := array['EUR','GBP','AUD','NZD','USD','JPY','CHF','CAD'];
        base text := left(p_symbol, 3); quote text := right(p_symbol, 3); rate numeric;
begin
  if p_entry is null or p_stop is null or p_entry <= 0 then return null; end if;
  if (select value ? p_symbol from app_config where key = 'usd_per_point_001') then
    return round(abs(p_entry - p_stop) * ((select value from app_config where key = 'usd_per_point_001') ->> p_symbol)::numeric, 2);
  end if;
  if length(p_symbol) <> 6 or not (base = any(fx) and quote = any(fx)) then return null; end if;
  if quote = 'USD' then return round(abs(p_entry - p_stop) * 1000, 2); end if;
  if base = 'USD' then return round(abs(p_entry - p_stop) * 1000 / p_entry, 2); end if;
  select close into rate from prices_m5 where symbol = quote || 'USD' order by t desc limit 1;      -- GBP, AUD, NZD, EUR
  if rate is not null then return round(abs(p_entry - p_stop) * 1000 * rate, 2); end if;
  select close into rate from prices_m5 where symbol = 'USD' || quote order by t desc limit 1;      -- JPY, CHF, CAD
  if rate is not null and rate > 0 then return round(abs(p_entry - p_stop) * 1000 / rate, 2); end if;
  return null;
end $$;
revoke all on function public.risk_usd_001_of(text, numeric, numeric) from public, anon;
