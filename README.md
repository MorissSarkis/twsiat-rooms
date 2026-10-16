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

## Other instruments (same rules, no re-tuning; Jan 2020 – Oct 2026, Exness M5, spread included)

| Instrument | Trades | Win % | Avg R (half/BE/TP2) | 2020–23 | 2024–26 | Max DD | Engine |
|---|---|---|---|---|---|---|---|
| XAUUSD | 641 | 52.7 | +0.096 | +0.061 | +0.148 | 14.9R | yes |
| BTCUSD | 793 | 52.2 | +0.070 | +0.063 | +0.079 | 21.7R | yes (db/011) |
| USDCAD | 529 | 50.9 | +0.025 | +0.019 | +0.032 | 32.9R | no — edge too small |
| USDJPY | 665 | 49.0 | +0.020 | +0.015 | +0.025 | 33.4R | no — edge too small |
| USOIL | 558 | 51.1 | +0.014 | −0.003 | +0.040 | 26.2R | no |
| XAGUSD | 617 | 48.1 | −0.002 | +0.051 | −0.076 | 40.6R | no |
| EURUSD | 586 | 50.3 | −0.026 | −0.063 | +0.029 | 31.3R | no |
| AUDUSD | 559 | 45.4 | −0.090 | −0.048 | −0.141 | 65.1R | no |

Rule to join the engine: average ≥ +0.05R in both 2020–23 and 2024–26. Indices, ETH, GBPUSD, USDCHF: not enough M5 history at Exness yet.

## Decisions (Oct 2026)

- Rooms: room 1 = accounts under $1,000, room 2 = $1,000 and above, room 3 = community.
- Login by email / Google. Broker account number is entered once, only to verify the IB client.
- Room 1 is not forced onto cent accounts; the client must accept a risk disclaimer to enter.
- Engine suggestions and analyst signals both go through the checker; an account manager approves before publishing.
- Clients may take TP1 only, or half at TP1 and the rest to TP2; the record shows both results.
- Telegram channel gets alerts without price levels (levels stay inside the rooms).
- Community room: ideas posted only through `community_post()` (server price and time, no edits or deletes), tracked on the same M5 prices; ranking starts after 20 closed trades.
- Levels page: classic pivots (R1–R3, S1–S3), previous-day range, Fibonacci of that range in the trend direction, ATR, daily and H1 trend.
