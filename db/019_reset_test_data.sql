-- 019: wipe test data before launch. Keeps prices, users/profiles, consents, config and secrets.
-- Removes: published signals (incl. shadow), engine suggestions, community ideas, engine log. Counters restart from 1.
truncate table public.signals, public.suggestions, public.community_trades, public.engine_log restart identity;
select (select count(*) from public.signals) signals, (select count(*) from public.suggestions) suggestions,
       (select count(*) from public.community_trades) community, (select count(*) from public.prices_m5) prices_kept;
