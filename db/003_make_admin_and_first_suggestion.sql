-- Run AFTER you have signed up on the site once.
-- 1) Make yourself admin (change the email):
update public.profiles set role = 'admin', ib_verified = true, room = 2, balance_usd = 5000
where id = (select id from auth.users order by created_at limit 1);  -- first account = owner

-- 2) First real engine suggestion — gold, 14 Oct 2026 (server time GMT):
insert into public.suggestions
  (source, symbol, side, order_type, entry, stop_loss, tp1, tp2, expires_at,
   check_passed, check_reasons, hist_win_rate, hist_avg_r, hist_sample, risk_usd_001)
values
  ('engine', 'XAUUSD', 'SELL', 'SELL_LIMIT', 4167.35, 4214.28, 4120.42, 4026.56, '2026-10-14 20:00:00+00',
   true,
   '[{"rule":"daily_trend","ok":true,"detail":"prev close 4154.94 below SMA50"},
     {"rule":"h1_trend","ok":true,"detail":"H1 EMA50 below EMA200"},
     {"rule":"entry_at_pivot","ok":true,"detail":"P = 4167.35"},
     {"rule":"stop_atr","ok":true,"detail":"0.7 x ATR = 46.93"}]',
   52.6, 0.094, 645, 46.9);
