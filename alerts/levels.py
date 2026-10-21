"""Pivot levels, ATR and trend detection (higher highs / lower lows)."""
from dataclasses import dataclass, asdict

import numpy as np
import pandas as pd


@dataclass
class Levels:
    day: str          # date of the completed bar the levels were built from
    P: float
    R1: float
    R2: float
    R3: float
    S1: float
    S2: float
    S3: float

    def as_dict(self):
        return asdict(self)


def classic_pivots(high: float, low: float, close: float, day: str) -> Levels:
    """Classic (floor) pivots from the previous completed day."""
    p = (high + low + close) / 3.0
    rng = high - low
    return Levels(
        day=day,
        P=p,
        R1=2 * p - low,
        S1=2 * p - high,
        R2=p + rng,
        S2=p - rng,
        R3=high + 2 * (p - low),
        S3=low - 2 * (high - p),
    )


def levels_from_daily(daily: pd.DataFrame) -> Levels:
    """daily: completed daily bars only (index = timestamp), columns open/high/low/close."""
    last = daily.iloc[-1]
    day = pd.Timestamp(daily.index[-1]).strftime("%Y-%m-%d")
    return classic_pivots(float(last["high"]), float(last["low"]), float(last["close"]), day)


def atr(daily: pd.DataFrame, n: int = 14) -> float:
    h, l, c = daily["high"], daily["low"], daily["close"]
    prev_c = c.shift(1)
    tr = pd.concat([h - l, (h - prev_c).abs(), (l - prev_c).abs()], axis=1).max(axis=1)
    return float(tr.tail(n).mean())


def swing_points(bars: pd.DataFrame, k: int = 2):
    """Confirmed swing highs/lows: a bar whose high (low) is the extreme of the
    k bars on each side. The last k bars can't be confirmed yet."""
    highs, lows = bars["high"].values, bars["low"].values
    sh, sl = [], []
    for i in range(k, len(bars) - k):
        window_h = highs[i - k:i + k + 1]
        window_l = lows[i - k:i + k + 1]
        if highs[i] == window_h.max() and (window_h == highs[i]).sum() == 1:
            sh.append(float(highs[i]))
        if lows[i] == window_l.min() and (window_l == lows[i]).sum() == 1:
            sl.append(float(lows[i]))
    return sh, sl


def structure_trend(bars: pd.DataFrame, k: int = 5):
    """The client's rule: the trend is UP as long as the long-term bottom holds,
    DOWN as long as the long-term top holds.

    Walks the bars in time order:
      - A close above the last confirmed swing high = break of structure up.
        Trend becomes up; the bottom = lowest low between that swing high and now.
      - Each later break above a new swing high moves the bottom up to the new,
        higher pullback low (never down).
      - A close below the bottom ends the uptrend: trend becomes down and the top
        = highest high since the bottom was made.
      - Mirror image for downtrends.
    Returns (trend, anchor) where anchor is the bottom (up) or top (down)."""
    h, l, c = bars["high"].values, bars["low"].values, bars["close"].values
    trend, anchor, anchor_i = "range", None, None
    sh = sh_i = sl = sl_i = None
    for t in range(len(bars)):
        i = t - k
        if i >= k:
            wh, wl = h[i - k:i + k + 1], l[i - k:i + k + 1]
            if h[i] == wh.max() and (wh == h[i]).sum() == 1:
                sh, sh_i = h[i], i
            if l[i] == wl.min() and (wl == l[i]).sum() == 1:
                sl, sl_i = l[i], i

        if trend == "up":
            if c[t] < anchor:
                j = anchor_i + int(np.argmax(h[anchor_i:t + 1]))
                trend, anchor, anchor_i = "down", float(h[j]), j
                sh = sl = None
            elif sh is not None and sh_i > anchor_i and c[t] > sh:
                j = sh_i + int(np.argmin(l[sh_i:t + 1]))
                if l[j] > anchor:
                    anchor, anchor_i = float(l[j]), j
                sh = None
        elif trend == "down":
            if c[t] > anchor:
                j = anchor_i + int(np.argmin(l[anchor_i:t + 1]))
                trend, anchor, anchor_i = "up", float(l[j]), j
                sh = sl = None
            elif sl is not None and sl_i > anchor_i and c[t] < sl:
                j = sl_i + int(np.argmax(h[sl_i:t + 1]))
                if h[j] < anchor:
                    anchor, anchor_i = float(h[j]), j
                sl = None
        else:
            if sh is not None and c[t] > sh:
                j = sh_i + int(np.argmin(l[sh_i:t + 1]))
                trend, anchor, anchor_i = "up", float(l[j]), j
                sh = None
            elif sl is not None and c[t] < sl:
                j = sl_i + int(np.argmax(h[sl_i:t + 1]))
                trend, anchor, anchor_i = "down", float(h[j]), j
                sl = None
    return trend, anchor


def detect_trend(bars: pd.DataFrame, k: int = 2) -> str:
    """'up'   = last swing high > previous AND last swing low > previous,
                and price hasn't closed below the last swing low.
       'down' = mirror image.
       'range' = anything else."""
    sh, sl = swing_points(bars, k)
    if len(sh) < 2 or len(sl) < 2:
        return "range"
    close = float(bars["close"].iloc[-1])
    if sh[-1] > sh[-2] and sl[-1] > sl[-2] and close > sl[-1]:
        return "up"
    if sh[-1] < sh[-2] and sl[-1] < sl[-2] and close < sh[-1]:
        return "down"
    return "range"
