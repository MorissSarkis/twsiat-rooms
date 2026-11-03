"""
Twsiat Rooms — engine v2 rules (gold, intraday, H1).

Found with the MT5 Strategy Tester (TwsiatSignalEngine2.mq5): chosen on 2020–23, confirmed on 2024–26.
  - Direction: previous D1 close vs EMA50(D1) AND previous H4 close vs EMA50(H4) must agree.
  - Levels:    classic (floor) daily pivots, day = New York close (21:00/22:00 GMT, US DST).
  - Trigger:   closed H1 bar touches P / S1 / S2 (buy) or P / R1 / R2 (sell), within 0.15 x ATR(H1),
               and closes back on the trend side, no more than 0.6 x ATR away from the level.
  - Stop:      entry -/+ 2.5 x ATR(14, H1).
  - Targets:   TP1 = 1.8R, TP2 = first pivot level beyond TP1 (else TP1 + 1R).
               Half at TP1, stop to entry, rest to TP2. Time stop 48 h, Friday close 20:00.
  - Hours:     signals tested 12:00–20:00 server time (GMT). Earlier hours were negative.
  - Limits:    max 2 signals per pivot day; no new signal while one is open.
All times are broker server time (Exness = GMT+0).
"""
from __future__ import annotations
import numpy as np
import pandas as pd

CONFIG2 = dict(
    trend_ema=50,
    atr_h1=14,
    tol_atr=0.15,
    max_entry_atr=0.60,
    sl_atr=2.5,
    tp1_r=1.8,
    sess_start=12,
    sess_end=20,
    friday_last_signal_hour=18,
    friday_close_hour=20,
    max_per_day=2,
    max_hold_hours=48,
    ny_close_winter=22,
    ny_close_summer=21,
)
NAMES = ['S3', 'S2', 'S1', 'P', 'R1', 'R2', 'R3']


# ---------- helpers ----------
def _nth_sunday(year, month, n):
    d = pd.Timestamp(year=year, month=month, day=1)
    d += pd.Timedelta(days=(6 - d.dayofweek) % 7)          # first Sunday (Mon=0 .. Sun=6)
    return d + pd.Timedelta(days=7 * (n - 1))


def us_summer(t: pd.Timestamp) -> bool:
    return _nth_sunday(t.year, 3, 2) <= t < _nth_sunday(t.year, 11, 1)


def ny_day_start(t: pd.Timestamp) -> pd.Timestamp:
    """Start of the New-York-close trading day that contains t."""
    h = CONFIG2['ny_close_summer'] if us_summer(t) else CONFIG2['ny_close_winter']
    s = t.normalize() + pd.Timedelta(hours=h)
    return s if s <= t else s - pd.Timedelta(days=1)


def build_h1(m5: pd.DataFrame) -> pd.DataFrame:
    h = m5.set_index('t').resample('1h').agg(
        {'open': 'first', 'high': 'max', 'low': 'min', 'close': 'last', 'spread': 'last'}).dropna()
    tr = pd.concat([h.high - h.low, (h.high - h.close.shift()).abs(),
                    (h.low - h.close.shift()).abs()], axis=1).max(axis=1)
    h['atr'] = tr.rolling(CONFIG2['atr_h1']).mean()
    return h


def trend_series(m5: pd.DataFrame):
    """Closed D1 and H4 bars with their EMA50. Sunday mini-candles are merged into Monday."""
    s = m5.set_index('t')
    d = s.close.resample('1D').last().dropna()
    d = d[d.index.dayofweek != 6]
    h4 = s.close.resample('4h').last().dropna()
    n = CONFIG2['trend_ema']
    return (pd.DataFrame({'c': d, 'e': d.ewm(span=n, adjust=False).mean()}),
            pd.DataFrame({'c': h4, 'e': h4.ewm(span=n, adjust=False).mean()}))


def trend_at(t: pd.Timestamp, d1: pd.DataFrame, h4: pd.DataFrame) -> int:
    """+1 up, -1 down, 0 mixed. Uses bars that closed before t."""
    dd = d1[d1.index + pd.Timedelta(days=1) <= t]
    hh = h4[h4.index + pd.Timedelta(hours=4) <= t]
    if len(dd) < CONFIG2['trend_ema'] or len(hh) < CONFIG2['trend_ema']:
        return 0
    up_d = dd.c.iloc[-1] > dd.e.iloc[-1]
    up_h = hh.c.iloc[-1] > hh.e.iloc[-1]
    if up_d and up_h:
        return 1
    if (not up_d) and (not up_h):
        return -1
    return 0


def pivots_for(day_start: pd.Timestamp, h1: pd.DataFrame):
    """Floor pivots from the previous NY-close day (skips weekend gaps)."""
    end = day_start
    for _ in range(4):
        start = end - pd.Timedelta(days=1)
        w = h1[(h1.index >= start) & (h1.index < end)]
        if len(w) >= 3:
            H, L, C = w.high.max(), w.low.min(), w.close.iloc[-1]
            P = (H + L + C) / 3
            r = H - L
            return np.array([L - 2 * (H - P), P - r, 2 * P - H, P, 2 * P - L, P + r, H + 2 * (P - L)])
        end = start
    return None


# ---------- signal at a closed H1 bar ----------
def signal_at(bar, lv, trend: int, digits=2):
    """bar: closed H1 row (open, high, low, close, spread, atr). Returns dict or None."""
    if trend == 0 or lv is None or not bar.atr > 0:
        return None
    atr, tol = bar.atr, CONFIG2['tol_atr'] * bar.atr
    o, h, l, c = bar.open, bar.high, bar.low, bar.close
    idx = None
    if trend == 1:
        for i in (1, 2, 3):                                   # S2, S1, P
            if l <= lv[i] + tol and c > lv[i] and c - lv[i] <= CONFIG2['max_entry_atr'] * atr:
                idx = i; break
    else:
        for i in (5, 4, 3):                                   # R2, R1, P
            if h >= lv[i] - tol and c < lv[i] and lv[i] - c <= CONFIG2['max_entry_atr'] * atr:
                idx = i; break
    if idx is None:
        return None
    s = trend
    entry = c + (bar.spread if s == 1 else 0.0)              # buy at ask, sell at bid
    risk = CONFIG2['sl_atr'] * atr
    sl = entry - s * risk
    tp1 = entry + s * CONFIG2['tp1_r'] * risk
    tp2 = None
    k = idx + s
    while 0 <= k <= 6:
        if (lv[k] - tp1) * s > 0:
            tp2 = lv[k]; break
        k += s
    if tp2 is None:
        tp2 = tp1 + s * risk
    return dict(side='BUY' if s == 1 else 'SELL', level=NAMES[idx],
                entry=round(entry, digits), stop_loss=round(sl, digits),
                tp1=round(tp1, digits), tp2=round(tp2, digits), atr=round(atr, digits))


def in_tested_hours(t: pd.Timestamp) -> bool:
    if t.dayofweek == 4 and t.hour >= CONFIG2['friday_last_signal_hour']:
        return False
    return CONFIG2['sess_start'] <= t.hour < CONFIG2['sess_end']


# ---------- tracking (half at TP1, BE, TP2, 48 h, Friday close) ----------
def track2(side, entry, stop, tp1, tp2, T, H, L, C, SP, fill):
    buy = side == 'BUY'
    sld = abs(entry - stop)
    t0 = pd.Timestamp(T[fill])
    end = t0 + pd.Timedelta(hours=CONFIG2['max_hold_hours'])
    fri = t0.normalize() + pd.Timedelta(days=(4 - t0.dayofweek) % 7, hours=CONFIG2['friday_close_hour'])
    end = np.datetime64(min(end, fri) if fri > t0 else end)
    r1, r2 = abs(tp1 - entry) / sld, abs(tp2 - entry) / sld
    half = False; cur = stop; tp1only = partial = None
    j = fill
    while j < len(T) and T[j] < end:
        lo = L[j] if buy else L[j] + SP[j]
        hi = H[j] if buy else H[j] + SP[j]
        if (lo <= cur) if buy else (hi >= cur):
            if tp1only is None: tp1only = -1.0
            partial = 0.5 * r1 if half else -1.0
            break
        if j > fill:
            if not half and ((hi >= tp1) if buy else (lo <= tp1)):
                half = True; tp1only = r1; cur = entry
            if half and ((hi >= tp2) if buy else (lo <= tp2)):
                partial = 0.5 * r1 + 0.5 * r2
                break
        j += 1
    if partial is None:
        px = C[min(j, len(T) - 1)] - (0 if buy else -SP[min(j, len(T) - 1)])
        m = ((px - entry) if buy else (entry - px)) / sld
        partial = 0.5 * r1 + 0.5 * m if half else m
        if tp1only is None: tp1only = m
    return dict(tp1_hit=half, r_partial=round(float(partial), 3), r_tp1only=round(float(tp1only), 3),
                closed_at=pd.Timestamp(T[min(j, len(T) - 1)]))
