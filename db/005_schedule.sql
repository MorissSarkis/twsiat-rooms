-- 005: run the engine every 5 minutes and create the MT5 bridge token.
-- Run once in the Supabase SQL Editor.

create extension if not exists pg_cron;

select cron.schedule('engine-tick', '*/5 * * * *', $$select public.engine_tick()$$);

-- Bridge token: a random secret the MT5 bridge must send with prices.
insert into public.app_secrets (name, value) values ('bridge_token', replace(gen_random_uuid()::text, '-', ''))
on conflict (name) do nothing;
select value as bridge_token_copy_this_into_mt5 from public.app_secrets where name = 'bridge_token';
