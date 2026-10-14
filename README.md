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

Rules (`engine/rules.py`): daily trend (close vs SMA50) + H1 trend (EMA50 vs EMA200) must agree;
pending entry at the daily pivot P; stop 0.7 × daily ATR; TP1 = 1R, TP2 = 3R; pending order expires 20:00 GMT.

| Client style | Trades | Win % | Avg R | Total R | Max drawdown |
|---|---|---|---|---|---|
| Half at TP1, stop to entry, rest to TP2 | 645 (~98/yr) | 52.6% | +0.094 | +60.6 | 15.3R |
| TP1 only | 645 | 52.6% | +0.054 | +35.1 | 19.9R |

By year (half/BE/TP2): 2020 −5 · 2021 +8 · 2022 0 · 2023 +19 · 2024 +5 · 2025 +27 · 2026 +7 (R).

Reproduce: `python engine/backtest.py XAUUSDm_M5.csv` (MT5 "Export Bars" file).

## Decisions (Oct 2026)

- Rooms: room 1 = accounts under $1,000, room 2 = $1,000 and above, room 3 = community.
- Login by email / Google. Broker account number is entered once, only to verify the IB client.
- Room 1 is not forced onto cent accounts; the client must accept a risk disclaimer to enter.
- Engine suggestions and analyst signals both go through the checker; an account manager approves before publishing.
- Clients may take TP1 only, or half at TP1 and the rest to TP2; the record shows both results.
