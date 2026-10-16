"""
Twsiat Rooms — signal rules (Phase 1 result, gold only).

Validated on XAUUSD M5, Jan 2020 – Oct 2026 (chosen on 2020–23, confirmed on 2024–26):
  - Direction: daily trend (previous daily close vs 50-day SMA) AND
               H1 trend (EMA50 vs EMA200, at the first bar of the day) must agree with the trade.
  - Entry:     pending order at the daily classic pivot P (pullback with the trend).
  - Stop:      0.7 x ATR(14, daily) from entry.
  - Targets:   TP1 = 1R, TP2 = 3R. Management: half at TP1, stop to entry, rest to TP2.
  - Expiry:    pending order cancelled at 20:00 server time (GMT) the same day.

All times are broker server time (Exness = GMT+0).
"""
from __future__ import annotations
from dataclasses import dataclass, field, asdict
import numpy as np
import pandas as pd

CONFIG = dict(
    sma_days=50,
    ema_fast_h1=50,
    ema_slow_h1=200,
    atr_days=14,
    sl_atr_mult=0.7,
    tp1_r=1.0,
    tp2_r=3.0,
    expiry_hour=20,
    max_hold_days=5,
    # analyst-signal checks
    min_tp1_r=0.8,          # TP1 must be at least ~1R away
    max_sl_atr=1.2,         # stop wider than this x ATR is rejected
    min_sl_atr=0.25,        # stop tighter than this is noise
    news_block_minutes=30,  # no new entries this close to a high-impact release
    usd_per_point_001={'XAUUSD': 1.0},  # $ per 1.0 price move per 0.01 lot
)


# ---------- indicators ----------
def daily_bars(m5: pd.DataFrame) -> pd.DataFrame:
    """m5: columns t, open, high, low, close (t = server time)."""
    d = m5.set_index('t').resample('1D').agg(
        {'open': 'first', 'high': 'max', 'low': 'min', 'close': 'last'}).dropna()
    tr = pd.concat([d.high - d.low, (d.high - d.close.shift()).abs(),
                    (d.low - d.close.shift()).abs()], axis=1).max(axis=1)
    d['atr'] = tr.rolling(CONFIG['atr_days']).mean()
    d['sma'] = d.close.rolling(CONFIG['sma_days']).mean()
    p = (d.high + d.low + d.close) / 3
    d['P'] = p
    d['R1'] = 2 * p - d.low
    d['S1'] = 2 * p - d.high
    d['R2'] = p + (d.high - d.low)
    d['S2'] = p - (d.high - d.low)
    return d


def h1_trend(m5: pd.DataFrame) -> pd.Series:
    """True = up. Value at hour h uses only closed H1 bars."""
    c = m5.set_index('t').close.resample('1h').last().dropna()
    up = c.ewm(span=CONFIG['ema_fast_h1']).mean() > c.ewm(span=CONFIG['ema_slow_h1']).mean()
    return up.shift(1)


@dataclass
class Context:
    """Market state for one trading day, built only from data known before it."""
    day: pd.Timestamp
    P: float; R1: float; S1: float; R2: float; S2: float
    atr: float
    daily_up: bool
    prev_close: float


def context_for(day: pd.Timestamp, daily: pd.DataFrame) -> Context | None:
    prev = daily[daily.index < day.normalize()]
    if len(prev) < CONFIG['sma_days']:
        return None
    x = prev.iloc[-1]
    return Context(day=day.normalize(), P=x.P, R1=x.R1, S1=x.S1, R2=x.R2, S2=x.S2,
                   atr=x.atr, daily_up=bool(x.close > x.sma), prev_close=x.close)


def h1_up_at(t: pd.Timestamp, h1: pd.Series) -> bool | None:
    s = h1[h1.index <= t]
    if s.empty or pd.isna(s.iloc[-1]):
        return None
    return bool(s.iloc[-1])


# ---------- engine suggestion ----------
@dataclass
class Suggestion:
    symbol: str
    side: str
    order_type: str
    entry: float
    stop_loss: float
    tp1: float
    tp2: float
    expires_at: pd.Timestamp
    risk_usd_001: float
    reasons: list = field(default_factory=list)

    def to_dict(self):
        d = asdict(self); d['expires_at'] = str(self.expires_at); return d


def engine_suggestion(ctx: Context, day_open: float, symbol='XAUUSD', digits: int = 2) -> Suggestion | None:
    """Daily suggestion at the pivot, in the direction of the daily trend.
    The H1 condition is checked at the first bar of the day (see confirm_fill)."""
    buy = ctx.daily_up
    E = ctx.P
    if buy and day_open <= E:      # must be a pullback (limit order below price)
        return None
    if (not buy) and day_open >= E:
        return None
    sld = CONFIG['sl_atr_mult'] * ctx.atr
    s = 1 if buy else -1
    return Suggestion(
        symbol=symbol, side='BUY' if buy else 'SELL',
        order_type='BUY_LIMIT' if buy else 'SELL_LIMIT',
        entry=round(E, digits), stop_loss=round(E - s * sld, digits),
        tp1=round(E + s * CONFIG['tp1_r'] * sld, digits), tp2=round(E + s * CONFIG['tp2_r'] * sld, digits),
        expires_at=ctx.day + pd.Timedelta(hours=CONFIG['expiry_hour']),
        risk_usd_001=round(sld * CONFIG['usd_per_point_001'][symbol], 1),
        reasons=[
            dict(rule='daily_trend', ok=True,
                 detail=f"prev close {ctx.prev_close:.2f} {'above' if buy else 'below'} SMA{CONFIG['sma_days']}"),
            dict(rule='entry_at_pivot', ok=True, detail=f"P = {E:.2f}"),
            dict(rule='stop_atr', ok=True, detail=f"{CONFIG['sl_atr_mult']} x ATR = {sld:.2f}"),
        ])


def confirm_fill(side: str, t: pd.Timestamp, h1: pd.Series) -> bool:
    up = h1_up_at(t, h1)
    return up is not None and up == (side == 'BUY')


# ---------- analyst signal check ----------
def check_signal(side: str, entry: float, stop: float, tp1: float, t: pd.Timestamp,
                 ctx: Context, h1: pd.Series, news_times: list[pd.Timestamp] | None = None) -> list[dict]:
    """Returns a list of {rule, ok, detail}. Signal passes if all ok."""
    buy = side == 'BUY'
    out = []
    out.append(dict(rule='levels_order', ok=(stop < entry < tp1) if buy else (tp1 < entry < stop),
                    detail='SL / entry / TP on the correct sides'))
    out.append(dict(rule='daily_trend', ok=ctx.daily_up == buy,
                    detail=f"daily trend is {'UP' if ctx.daily_up else 'DOWN'}"))
    up = h1_up_at(t, h1)
    out.append(dict(rule='h1_trend', ok=(up is not None and up == buy),
                    detail=f"H1 trend is {'UP' if up else 'DOWN' if up is not None else 'unknown'}"))
    sld = abs(entry - stop)
    ratio = sld / ctx.atr if ctx.atr else np.nan
    out.append(dict(rule='stop_size', ok=CONFIG['min_sl_atr'] <= ratio <= CONFIG['max_sl_atr'],
                    detail=f"stop = {ratio:.2f} x daily ATR (allowed {CONFIG['min_sl_atr']}–{CONFIG['max_sl_atr']})"))
    r1 = abs(tp1 - entry) / sld if sld else 0
    out.append(dict(rule='tp1_distance', ok=r1 >= CONFIG['min_tp1_r'],
                    detail=f"TP1 = {r1:.2f}R (min {CONFIG['min_tp1_r']}R)"))
    if news_times is not None:
        near = [n for n in news_times if abs((n - t).total_seconds()) <= CONFIG['news_block_minutes'] * 60]
        out.append(dict(rule='news', ok=not near,
                        detail='no high-impact news within 30 min' if not near else f"news at {near[0]}"))
    return out


# ---------- tracking ----------
def track(side: str, entry: float, stop: float, tp1: float, tp2: float | None,
          bars: pd.DataFrame, filled_idx: int = 0, max_hold_days: int | None = None) -> dict:
    """Walk M5 bars after fill. bars: t, high, low, close, spread (price units).
    Returns outcome for both client styles: TP1-only and half/BE/TP2.
    Conservative: if a bar touches SL and a target, SL counts first."""
    max_hold_days = max_hold_days or CONFIG['max_hold_days']
    buy = side == 'BUY'
    sld = abs(entry - stop)
    T, H, L, C, SP = (bars[c].values for c in ['t', 'high', 'low', 'close', 'spread'])
    end = T[filled_idx] + np.timedelta64(max_hold_days * 24, 'h')
    r_tp1 = abs(tp1 - entry) / sld
    r_tp2 = abs(tp2 - entry) / sld if tp2 else None
    tp1_only = None; partial = None; half = False; cur_stop = stop
    tp1_t = closed_t = None
    j = filled_idx
    while j < len(T) and T[j] <= end:
        lo = L[j] if buy else L[j] + SP[j]
        hi = H[j] if buy else H[j] + SP[j]
        if (lo <= cur_stop) if buy else (hi >= cur_stop):
            if tp1_only is None: tp1_only = -1.0
            partial = 0.5 * r_tp1 if half else -1.0
            closed_t = T[j]; break
        if j > filled_idx:
            if not half and ((hi >= tp1) if buy else (lo <= tp1)):
                half = True; tp1_only = r_tp1; tp1_t = T[j]; cur_stop = entry
                if not tp2:
                    partial = r_tp1; closed_t = T[j]; break
            if half and tp2 and ((hi >= tp2) if buy else (lo <= tp2)):
                partial = 0.5 * r_tp1 + 0.5 * r_tp2; closed_t = T[j]; break
        j += 1
    if partial is None:  # time exit
        px = C[min(j, len(T) - 1)]
        m = ((px - entry) if buy else (entry - px)) / sld
        partial = 0.5 * r_tp1 + 0.5 * m if half else m
        if tp1_only is None: tp1_only = m
        closed_t = T[min(j, len(T) - 1)]
    return dict(tp1_hit=half, tp1_at=tp1_t, closed_at=closed_t,
                result_r_tp1only=round(float(tp1_only), 3), result_r_partial=round(float(partial), 3))
