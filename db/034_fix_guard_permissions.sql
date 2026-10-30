-- 034: fix "permission denied for table app_config" when publishing a signal (032/033 triggers ran as the user).
-- The helper and triggers now run with the database owner's rights, like the other system functions. Safe to run more than once.
alter function public.risk_usd_001_of(text, numeric, numeric) security definer;
alter function public.signal_guard() security definer;
alter function public.suggestion_risk() security definer;
alter function public.signals_orig_stop() security definer;
revoke all on function public.risk_usd_001_of(text, numeric, numeric) from public, anon;
