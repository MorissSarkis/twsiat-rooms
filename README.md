# Twsiat Rooms

Members area for twsiat.com clients: expert signal rooms (by account size), a community room,
pivot levels and tools. Signals are checked by rules before they reach clients, and every signal
is tracked automatically against live prices.

## Structure

| Folder | What it holds |
|---|---|
| `engine/` | Signal rules (checker + daily engine suggestion) and outcome tracking — Python |
| `db/` | Supabase / Postgres schema and security policies |
| `web/` | Web app (Next.js) — Phase 2 |
| `docs/` | Decisions and results |

## Phase 1 result (gold, Jan 2020 – Oct 2026, M5, Exness prices, spread included)

Rules (`engine/rules.py`, same logic in the database: `db/004_engine.sql`): daily trend (close vs SMA50) + H1 trend (EMA50 vs EMA200, checked when the suggestion is made) must agree;
pending entry at the daily pivot P; stop 0.7 × daily ATR; TP1 = 1R, TP2 = 3R; pending order expires 20:00 GMT.

| Client style | Trades | Win % | Avg R | Total R | Max drawdown |
|---|---|---|---|---|---|
| Half at TP1, stop to entry, rest to TP2 | 641 (~95/yr) | 52.7% | +0.096 | +61.6 | 14.9R |
| TP1 only | 641 | 52.7% | +0.058 | +37.0 | 19.9R |

By year (half/BE/TP2): 2020 −4 · 2021 +7 · 2022 +1 · 2023 +19 · 2024 +5 · 2025 +27 · 2026 +7 (R).

The database engine (`db/004_engine.sql`) was checked against this backtest on a local Postgres:
639 closed trades identical (side, entry, result to 0.01R).

Reproduce: `python engine/backtest.py XAUUSDm_M5.csv` (MT5 "Export Bars" file).

## Decisions (Oct 2026)

- Rooms: room 1 = accounts under $1,000, room 2 = $1,000 and above, room 3 = community.
- Login by email / Google. Broker account number is entered once, only to verify the IB client.
- Room 1 is not forced onto cent accounts; the client must accept a risk disclaimer to enter.
- Engine suggestions and analyst signals both go through the checker; an account manager approves before publishing.
- Clients may take TP1 only, or half at TP1 and the rest to TP2; the record shows both results.
- Telegram channel gets alerts without price levels (levels stay inside the rooms).
- Community room: ideas posted only through `community_post()` (server price and time, no edits or deletes), tracked on the same M5 prices; ranking starts after 20 closed trades.
- Levels page: classic pivots (R1–R3, S1–S3), previous-day range, Fibonacci of that range in the trend direction, ATR, daily and H1 trend.
