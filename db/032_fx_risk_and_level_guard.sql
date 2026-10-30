-- 032: correct risk ($ per 0.01 lot) for currencies, silver, Brent and ETH, and a hard guard against typos.
--  * Risk was computed with "1$ per 1.0 price move" for every symbol not in usd_per_point_001, so EUR/USD showed $0.0
--    and no lot size. 0.01 lot = 1,000 units of the base currency:
--      quote USD (EURUSD, GBPUSD, AUDUSD, NZDUSD): 1,000 $ per 1.0 move
--      base USD  (USDJPY, USDCHF, USDCAD):         1,000 / price $ per 1.0 move
--    silver 0.01 lot = 50 oz, Brent = WTI (10 $), ETH 0.01 coin.
--    Indices and natural gas: contract size differs by broker → risk left empty (no wrong lot size shown).
--  * Guard: a signal is refused if stop/targets are on the wrong side of the entry, or a target/stop is more than
--    20% away from the entry (e.g. 15,740 instead of 157.40).
-- Safe to run more than once.

update public.app_config
   set value = value || '{"EURUSD":1000,"GBPUSD":1000,"AUDUSD":1000,"NZDUSD":1000,"XAGUSD":50,"UKOIL":10,"ETHUSD":0.01}'::jsonb
 where key = 'usd_per_point_001';

create or replace function public.risk_usd_001_of(p_symbol text, p_entry numeric, p_stop numeric) returns numeric
language sql stable set search_path = public as $$
  select case
    when p_entry is null or p_stop is null or p_entry <= 0 then null
    when p_symbol in ('USDJPY','USDCHF','USDCAD') then round(abs(p_entry - p_stop) * 1000 / p_entry, 2)
    when (select value ? p_symbol from app_config where key = 'usd_per_point_001')
      then round(abs(p_entry - p_stop) * ((select value from app_config where key = 'usd_per_point_001') ->> p_symbol)::numeric, 2)
    else null end;
$$;

create or replace function public.signal_guard() returns trigger
language plpgsql set search_path = public as $$
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
  if abs(new.tp1 - new.entry) > 0.2 * new.entry or abs(new.stop_loss - new.entry) > 0.2 * new.entry
     or (new.tp2 is not null and abs(new.tp2 - new.entry) > 0.2 * new.entry) then
    raise exception 'رقم غريب: هدف أو ستوب بعيد أكتر من 20%% عن الدخول. تأكد من الفاصلة العشرية';
  end if;
  new.risk_usd_001 := risk_usd_001_of(new.symbol, new.entry, new.stop_loss);
  return new;
end $$;
drop trigger if exists signals_guard on public.signals;
create trigger signals_guard before insert on public.signals for each row when (not new.shadow) execute function public.signal_guard();

-- same risk on pending suggestions (what staff see before approving)
create or replace function public.suggestion_risk() returns trigger
language plpgsql set search_path = public as $$
begin
  new.risk_usd_001 := coalesce(risk_usd_001_of(new.symbol, new.entry, new.stop_loss), new.risk_usd_001);
  if new.symbol in ('US30','USTEC','US500','DE30','UK100','JP225','XNGUSD') then new.risk_usd_001 := null; end if;
  return new;
end $$;
drop trigger if exists suggestions_risk on public.suggestions;
create trigger suggestions_risk before insert on public.suggestions for each row execute function public.suggestion_risk();

-- fix signals already published
update public.signals set risk_usd_001 = risk_usd_001_of(symbol, entry, stop_loss)
 where not shadow and symbol not in ('XAUUSD','BTCUSD','USOIL');
update public.suggestions set risk_usd_001 = risk_usd_001_of(symbol, entry, stop_loss)
 where status = 'pending' and symbol not in ('XAUUSD','BTCUSD','USOIL');
