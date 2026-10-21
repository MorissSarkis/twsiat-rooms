"""Alert rules for the pivot ladder strategy.

Uptrend  -> buy ladder : pivot broken down, then S1 / S2 / S3 entries, stop if S3 breaks.
Downtrend-> sell ladder: pivot broken up,   then R1 / R2 / R3 entries, stop if R3 breaks.

Each alert fires once, then re-arms only after price moves clearly away from
the level (rearm distance), so chop around a level does not spam the group.
State resets every new pivot day.
"""
from dataclasses import dataclass

from levels import Levels


@dataclass
class Event:
    asset: str
    kind: str          # PIVOT_DOWN, PIVOT_UP, APPROACH, TOUCH, STOP
    side: str          # buy / sell / ''
    level_name: str
    level: float
    price: float
    trend: str
    severity: str      # info / entry / critical


class AlertEngine:
    def __init__(self, approach_atr=0.10, rearm_atr=0.30, stop_buffer_atr=0.05,
                 alert_without_trend=False, state=None, cross_buffer_atr=0.05):
        self.cross_buffer_atr = cross_buffer_atr
        self.approach_atr = approach_atr
        self.rearm_atr = rearm_atr
        self.stop_buffer_atr = stop_buffer_atr
        self.alert_without_trend = alert_without_trend
        self.state = state if state is not None else {}

    def _st(self, asset, day):
        st = self.state.get(asset)
        if st is None or st.get("day") != day:
            st = {"day": day, "fired": {}, "last_price": None}
            self.state[asset] = st
        return st

    @staticmethod
    def _check(st, key, cond, rearm):
        fired = st["fired"].get(key, False)
        if fired and rearm:
            st["fired"][key] = fired = False
        if not fired and cond:
            st["fired"][key] = True
            return True
        return False

    LEVEL_ORDER = ("R3", "R2", "R1", "P", "S1", "S2", "S3")

    def evaluate_all(self, asset: str, price: float, lv: Levels, trend: str, atr: float,
                     levels=("R3", "R2", "R1", "P", "S1", "S2", "S3"), approach=True):
        """'All levels' mode: alert whenever price reaches ANY level, falling or rising,
        regardless of trend. Trend is only shown as information in the message."""
        st = self._st(asset, lv.day)
        first = st["last_price"] is None     # first look at this asset today (or after a restart wipe)
        st["last_price"] = price
        a, r = self.approach_atr * atr, self.rearm_atr * atr
        h = self.cross_buffer_atr * atr
        lvl_state = st.setdefault("lvl", {})
        out = []
        for name in self.LEVEL_ORDER:
            if name not in levels:
                continue
            L = getattr(lv, name)
            # Each level remembers which side price is on, and whether price was clearly
            # away from it (>= h). A crossing only alerts if price came from clearly on
            # the other side, so wobbling around a level sends nothing new.
            s = lvl_state.get(name)
            if s is None:
                lvl_state[name] = {"side": "above" if price > L else "below", "clear": abs(price - L) >= h}
            else:
                if s["side"] == "above":
                    if price - L >= h:
                        s["clear"] = True
                    if price <= L:
                        if s["clear"]:
                            out.append(Event(asset, "CROSS", "down", name, L, price, trend, "entry"))
                        s["side"], s["clear"] = "below", L - price >= h
                else:
                    if L - price >= h:
                        s["clear"] = True
                    if price >= L:
                        if s["clear"]:
                            out.append(Event(asset, "CROSS", "up", name, L, price, trend, "entry"))
                        s["side"], s["clear"] = "above", price - L >= h
            if approach:
                if self._check(st, f"NEAR_DN_{name}", L < price <= L + a, price > L + a + r):
                    out.append(Event(asset, "NEAR", "down", name, L, price, trend, "info"))
                if self._check(st, f"NEAR_UP_{name}", L - a <= price < L, price < L - a - r):
                    out.append(Event(asset, "NEAR", "up", name, L, price, trend, "info"))
        # S3 broken in an uptrend / R3 broken in a downtrend = his "close everything" point
        b = self.stop_buffer_atr * atr
        if trend == "up" and "S3" in levels and \
                self._check(st, "STOP_BUY", price < lv.S3 - b, price > lv.S3 + r):
            out.append(Event(asset, "STOP", "down", "S3", lv.S3, price, trend, "critical"))
        if trend == "down" and "R3" in levels and \
                self._check(st, "STOP_SELL", price > lv.R3 + b, price < lv.R3 - r):
            out.append(Event(asset, "STOP", "up", "R3", lv.R3, price, trend, "critical"))

        # First look: only record where price already is. Conditions that were already true
        # before we started watching (e.g. "below S3") are not new events, so stay silent.
        if first:
            return []

        # several levels in one jump: falling -> top level first, rising -> bottom level first
        crossed = {e.level_name for e in out if e.kind == "CROSS"}
        stopped = {e.level_name for e in out if e.kind == "STOP"}
        out = [e for e in out if not (e.kind == "NEAR" and e.level_name in crossed)
               and not (e.kind == "CROSS" and e.level_name in stopped)]
        if out and out[0].side == "up":
            out.reverse()
        return out

    def evaluate(self, asset: str, price: float, lv: Levels, trend: str, atr: float, anchor=None):
        """anchor = the long-term bottom (uptrend) or top (downtrend) that defines the trend."""
        st = self._st(asset, lv.day)
        prev = st["last_price"]
        st["last_price"] = price
        a = self.approach_atr * atr
        r = self.rearm_atr * atr
        b = self.stop_buffer_atr * atr
        out = []

        def ev(kind, side, name, level, sev):
            out.append(Event(asset, kind, side, name, level, price, trend, sev))

        # Long-term bottom / top broken -> trend is over (checked before anything else)
        if anchor is not None:
            if trend == "up" and self._check(st, "TREND_BREAK", price < anchor - b, price > anchor + r):
                ev("TREND_BREAK", "buy", "BOTTOM", anchor, "critical")
                return out
            if trend == "down" and self._check(st, "TREND_BREAK", price > anchor + b, price < anchor - r):
                ev("TREND_BREAK", "sell", "TOP", anchor, "critical")
                return out

        if trend == "up":
            sides = ["buy"]
        elif trend == "down":
            sides = ["sell"]
        else:
            sides = ["buy", "sell"] if self.alert_without_trend else []
        if not sides:
            return out

        # Pivot crosses (the "ladder is now active" signal)
        if prev is not None:
            if "buy" in sides and self._check(st, "PIVOT_DOWN", prev >= lv.P > price, price > lv.P + r):
                ev("PIVOT_DOWN", "buy", "P", lv.P, "info")
            if "sell" in sides and self._check(st, "PIVOT_UP", prev <= lv.P < price, price < lv.P - r):
                ev("PIVOT_UP", "sell", "P", lv.P, "info")

        if "buy" in sides:
            for name in ("S1", "S2", "S3"):
                L = getattr(lv, name)
                touched = st["fired"].get(f"TOUCH_{name}", False)
                if self._check(st, f"REB_{name}", touched and price >= L + a, not touched):
                    ev("REBOUND", "buy", name, L, "entry")
                if self._check(st, f"APP_{name}", L < price <= L + a, price > L + a + r):
                    ev("APPROACH", "buy", name, L, "info")
                if self._check(st, f"TOUCH_{name}", price <= L, price > L + r):
                    ev("TOUCH", "buy", name, L, "entry")
            if self._check(st, "STOP_BUY", price < lv.S3 - b, price > lv.S3 + r):
                ev("STOP", "buy", "S3", lv.S3, "critical")

        if "sell" in sides:
            for name in ("R1", "R2", "R3"):
                L = getattr(lv, name)
                touched = st["fired"].get(f"TOUCH_{name}", False)
                if self._check(st, f"REB_{name}", touched and price <= L - a, not touched):
                    ev("REBOUND", "sell", name, L, "entry")
                if self._check(st, f"APP_{name}", L - a <= price < L, price < L - a - r):
                    ev("APPROACH", "sell", name, L, "info")
                if self._check(st, f"TOUCH_{name}", price >= L, price < L - r):
                    ev("TOUCH", "sell", name, L, "entry")
            if self._check(st, "STOP_SELL", price > lv.R3 + b, price < lv.R3 - r):
                ev("STOP", "sell", "R3", lv.R3, "critical")

        # If a level was jumped (gap), drop the stale "approaching" alert in the same tick
        # and if the stop fired, don't also send "entry 3" for the same level.
        touched = {e.level_name for e in out if e.kind in ("TOUCH", "STOP")}
        stopped = {e.level_name for e in out if e.kind == "STOP"}
        return [e for e in out
                if not (e.kind == "APPROACH" and e.level_name in touched)
                and not (e.kind == "TOUCH" and e.level_name in stopped)]


def fmt(x: float, digits=None) -> str:
    if digits is None:
        ax = abs(x)
        digits = 5 if ax < 10 else 3 if ax < 1000 else 2
    return f"{x:,.{digits}f}"


TREND_LABEL = {"up": "📈 Uptrend", "down": "📉 Downtrend", "range": "↔️ No clear trend"}


def format_event(e: Event, lv: Levels, digits=None) -> str:
    f = lambda v: fmt(v, digits)
    head = f"<b>{e.asset}</b> · {TREND_LABEL.get(e.trend, e.trend)}"
    step = {"S1": "1", "S2": "2", "S3": "3", "R1": "1", "R2": "2", "R3": "3"}.get(e.level_name, "")
    if e.kind == "PIVOT_DOWN":
        body = f"🔻 Broke DOWN through Pivot {f(e.level)}\nBuy ladder active: S1 {f(lv.S1)} · S2 {f(lv.S2)} · S3 {f(lv.S3)}"
    elif e.kind == "PIVOT_UP":
        body = f"🔺 Broke UP through Pivot {f(e.level)}\nSell ladder active: R1 {f(lv.R1)} · R2 {f(lv.R2)} · R3 {f(lv.R3)}"
    elif e.kind == "APPROACH":
        body = f"⏳ Approaching {e.level_name} {f(e.level)} — {e.side.upper()} zone {step} coming up"
    elif e.kind == "TOUCH":
        icon = "🟢" if e.side == "buy" else "🔴"
        body = f"{icon} Reached {e.level_name} {f(e.level)} — {e.side.upper()} entry {step}"
    elif e.kind == "CROSS":
        icon, way = ("🔻", "falling") if e.side == "down" else ("🔺", "rising")
        nm = "Pivot" if e.level_name == "P" else e.level_name
        body = f"{icon} Reached {nm} {f(e.level)} — price {way}"
    elif e.kind == "NEAR":
        way = "falling toward" if e.side == "down" else "rising toward"
        nm = "Pivot" if e.level_name == "P" else e.level_name
        body = f"⏳ Price {way} {nm} {f(e.level)}"
    elif e.kind == "REBOUND":
        way = "UP" if e.side == "buy" else "DOWN"
        body = f"↩️ Price turning {way} from {e.level_name} {f(e.level)} — reversal, add-on {e.side.upper()} point"
    elif e.kind == "TREND_BREAK":
        what = "Long-term BOTTOM" if e.side == "buy" else "Long-term TOP"
        trend = "uptrend" if e.side == "buy" else "downtrend"
        body = f"⚠️ {what} {f(e.level)} BROKEN — {trend} is over, no new {e.side.upper()}S"
    else:
        what = "BUYS" if e.side == "buy" else "SELLS"
        body = f"⛔ {e.level_name} BROKEN at {f(e.level)} — CLOSE ALL {what}"
    return f"{head}\n{body}\nPrice: {f(e.price)}"
