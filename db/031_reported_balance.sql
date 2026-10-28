-- 031: the member writes his current account balance in the activation form (what he says; staff confirm it).
-- Staff see it next to the request and the "activate" box is pre-filled with it. The real room/balance are still
-- set only by staff. Safe to run more than once.
alter table public.profiles add column if not exists reported_balance numeric;
alter table public.profiles drop constraint if exists profiles_reported_balance_check;
alter table public.profiles add constraint profiles_reported_balance_check
  check (reported_balance is null or (reported_balance >= 0 and reported_balance <= 100000000));
