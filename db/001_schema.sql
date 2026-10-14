-- Twsiat Rooms — database schema (Supabase / Postgres)
-- Phase 2: users, rooms, signals, suggestions, tracking, consent.

-- ---------- Users ----------
-- Supabase Auth owns auth.users (email + Google login).
-- profiles holds our own fields for each user.
create table public.profiles (
  id              uuid primary key references auth.users(id) on delete cascade,
  display_name    text,
  username        text unique,                 -- shown in the community room (room 3)
  role            text not null default 'client'
                  check (role in ('client','analyst','manager','admin')),
  ib_verified     boolean not null default false,  -- unlocks rooms 1 & 2
  broker          text,                        -- e.g. 'Exness'
  broker_account  text,                        -- entered once, only for verification (never shown)
  balance_usd     numeric,                     -- from the IB report; decides the room
  room            smallint check (room in (1,2)),  -- 1 = under $1,000, 2 = $1,000 and above
  verified_at     timestamptz,
  verified_by     uuid references auth.users(id),
  created_at      timestamptz not null default now()
);

-- Disclaimer consent: one row per user per room per disclaimer version.
create table public.consents (
  id            bigserial primary key,
  user_id       uuid not null references auth.users(id) on delete cascade,
  room          smallint not null check (room in (1,2,3)),
  version       text not null,                 -- disclaimer text version, e.g. 'r1-2026-10'
  accepted_at   timestamptz not null default now(),
  user_agent    text,
  unique (user_id, room, version)
);

-- ---------- Signals ----------
-- A suggestion is produced by the engine (or typed by an analyst) and waits in the back office.
create table public.suggestions (
  id              bigserial primary key,
  source          text not null check (source in ('engine','analyst')),
  created_by      uuid references auth.users(id),     -- analyst, when source = 'analyst'
  symbol          text not null,                      -- 'XAUUSD'
  side            text not null check (side in ('BUY','SELL')),
  order_type      text not null check (order_type in ('MARKET','BUY_LIMIT','SELL_LIMIT','BUY_STOP','SELL_STOP')),
  entry           numeric not null,
  stop_loss       numeric not null,
  tp1             numeric not null,
  tp2             numeric,
  expires_at      timestamptz,                        -- pending order expiry
  -- checker output
  check_passed    boolean not null,
  check_reasons   jsonb not null default '[]',        -- [{rule, ok, detail}]
  hist_win_rate   numeric,                            -- historical % for similar setups
  hist_avg_r      numeric,
  hist_sample     integer,
  risk_usd_001    numeric,                            -- $ risk per 0.01 lot
  status          text not null default 'pending'
                  check (status in ('pending','approved','rejected','expired')),
  decided_by      uuid references auth.users(id),
  decided_at      timestamptz,
  decision_note   text,
  created_at      timestamptz not null default now()
);

-- Published signals (an approved suggestion), visible in rooms 1/2.
create table public.signals (
  id              bigserial primary key,
  suggestion_id   bigint references public.suggestions(id),
  rooms           smallint[] not null,                -- e.g. {1,2}
  symbol          text not null,
  side            text not null,
  order_type      text not null,
  entry           numeric not null,
  stop_loss       numeric not null,
  tp1             numeric not null,
  tp2             numeric,
  risk_usd_001    numeric,
  published_at    timestamptz not null default now(),
  expires_at      timestamptz,
  -- tracking (filled by the engine, never by hand)
  state           text not null default 'waiting'
                  check (state in ('waiting','open','tp1','tp2','sl','be','expired','closed')),
  filled_at       timestamptz,
  tp1_at          timestamptz,
  closed_at       timestamptz,
  result_r_tp1only  numeric,     -- result if the client took TP1 only
  result_r_partial  numeric,     -- half at TP1, stop to entry, rest to TP2
  stop_moved_to   numeric,       -- official stop updates, logged
  notes           jsonb not null default '[]'
);

-- ---------- Community room (room 3) ----------
create table public.community_trades (
  id            bigserial primary key,
  user_id       uuid not null references auth.users(id) on delete cascade,
  symbol        text not null,
  side          text not null check (side in ('BUY','SELL')),
  order_type    text not null check (order_type in ('MARKET','BUY_LIMIT','SELL_LIMIT','BUY_STOP','SELL_STOP')),
  entry         numeric not null,     -- for MARKET: price is stamped by the server, not the user
  stop_loss     numeric not null,
  take_profit   numeric not null,
  posted_at     timestamptz not null default now(),
  expires_at    timestamptz,
  state         text not null default 'waiting'
                check (state in ('waiting','open','tp','sl','expired','closed')),
  filled_at     timestamptz,
  closed_at     timestamptz,
  result_r      numeric
  -- no update/delete for users: enforced by row-level security below
);

-- ---------- Prices (written by the MT5 price bridge) ----------
create table public.prices_m5 (
  symbol  text not null,
  t       timestamptz not null,
  open numeric, high numeric, low numeric, close numeric, spread numeric,
  primary key (symbol, t)
);

-- ---------- Row-level security ----------
alter table public.profiles          enable row level security;
alter table public.consents          enable row level security;
alter table public.suggestions       enable row level security;
alter table public.signals           enable row level security;
alter table public.community_trades  enable row level security;
alter table public.prices_m5         enable row level security;

create or replace function public.my_role() returns text
language sql stable security definer set search_path = public as
$$ select role from public.profiles where id = auth.uid() $$;

-- profiles: each user reads/updates own row (not role/verification fields — done by staff via server)
create policy "own profile read"   on public.profiles for select using (id = auth.uid() or public.my_role() in ('manager','admin'));
create policy "own profile insert" on public.profiles for insert with check (id = auth.uid());

-- consents: user writes own
create policy "own consent" on public.consents for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- suggestions: back office only
create policy "staff suggestions" on public.suggestions for all
  using (public.my_role() in ('analyst','manager','admin'))
  with check (public.my_role() in ('analyst','manager','admin'));

-- signals: verified users who accepted the room disclaimer can read their room; staff read all
create policy "room readers" on public.signals for select using (
  public.my_role() in ('analyst','manager','admin')
  or exists (
    select 1 from public.profiles p
    where p.id = auth.uid() and p.ib_verified and p.room = any(signals.rooms)
      and exists (select 1 from public.consents c where c.user_id = p.id and c.room = p.room)
  )
);

-- community: everyone signed in reads; only verified users post; nobody edits or deletes
create policy "community read" on public.community_trades for select using (auth.uid() is not null);
create policy "community post" on public.community_trades for insert with check (
  user_id = auth.uid()
  and exists (select 1 from public.profiles p where p.id = auth.uid() and p.ib_verified)
);

-- prices: readable by signed-in users (writes only via the service key)
create policy "prices read" on public.prices_m5 for select using (auth.uid() is not null);

-- ---------- New user -> profile row ----------
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email, '@', 1)));
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- API grants ----------
-- "Automatically expose new tables" is OFF in this project, so each table is granted explicitly.
-- Row-level security above still decides which rows each user can see.
grant usage on schema public to anon, authenticated;
grant select, insert            on public.profiles         to authenticated;
grant select, insert            on public.consents         to authenticated;
grant select, insert, update    on public.suggestions      to authenticated;
grant select                    on public.signals          to authenticated;
grant select, insert            on public.community_trades to authenticated;
grant select                    on public.prices_m5        to authenticated;
grant usage, select on all sequences in schema public to authenticated;
grant execute on function public.my_role() to authenticated;
