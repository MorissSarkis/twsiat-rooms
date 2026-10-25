"""English alert texts, the same facts as messages_ar.py: where the price went. No buy/sell advice."""
from engine import fmt

TREND_EN = {"up": "Rising ↗", "down": "Falling ↘", "range": "No clear trend ↔"}

LEVEL_EN = {
    "S1": "Support 1", "S2": "Support 2", "S3": "Support 3",
    "R1": "Resistance 1", "R2": "Resistance 2", "R3": "Resistance 3",
    "P": "Pivot",
}


def _lvl(code):
    return LEVEL_EN.get(code, code) if code == "P" else f"{LEVEL_EN.get(code, code)} ({code})"


def event_text(e, digits=None):
    """Returns (title, body, action), same shape as messages_ar.event_text."""
    f = lambda v: fmt(v, digits)
    trend = f"General trend: {TREND_EN.get(e.trend, e.trend)}"
    if e.kind == "CROSS":
        arrow = "📉" if e.side == "down" else "📈"
        if e.level_name == "P":
            title = f"{e.asset} {arrow} Price crossed the Pivot {'downward' if e.side == 'down' else 'upward'}"
        else:
            title = f"{e.asset} {arrow} Price reached {_lvl(e.level_name)}"
        body = f"{LEVEL_EN.get(e.level_name)}: {f(e.level)} · Price: {f(e.price)}\n{trend}"
        return title, body, e.side
    if e.kind == "NEAR":
        verb = "falling toward" if e.side == "down" else "rising toward"
        title = f"{e.asset} ⏳ Price {verb} {_lvl(e.level_name)}"
        body = f"{LEVEL_EN.get(e.level_name)}: {f(e.level)} · Price: {f(e.price)}\n{trend}"
        return title, body, "info"
    if e.kind == "STOP":
        title = f"{e.asset} ⚠️ Price broke {_lvl(e.level_name)}"
        body = f"{LEVEL_EN.get(e.level_name)}: {f(e.level)} · Price: {f(e.price)}\n{trend}"
        return title, body, "break"
    return f"{e.asset} {e.kind}", f"{e.level_name} {f(e.level)} · {f(e.price)}", "info"


def trend_change_text(asset, prev, new, anchor, digits=None):
    title = f"{asset} 🔄 General trend changed"
    body = f"Now {TREND_EN.get(new, new)} (was {TREND_EN.get(prev, prev)})"
    if anchor is not None and new in ("up", "down"):
        body += f"\n{'Bottom' if new == 'up' else 'Top'}: {fmt(anchor, digits)}"
    return title, body


def multi_cross_text(events, digits=None):
    """Price jumped through several levels at once: one message instead of many."""
    f = lambda v: fmt(v, digits)
    e0 = events[0]
    up = e0.side == "up"
    names = ", ".join(_lvl(e.level_name) for e in events)
    title = f"{e0.asset} {'📈' if up else '📉'} Price {'jumped' if up else 'dropped'} through {len(events)} levels"
    lines = [f"{LEVEL_EN.get(e.level_name)}: {f(e.level)}" for e in events]
    body = "\n".join(lines) + f"\nPrice: {f(events[-1].price)}\nGeneral trend: {TREND_EN.get(e0.trend, e0.trend)}"
    return title, body, e0.side, names


def anchor_broken_text(asset, trend, anchor, price, digits=None):
    what = "bottom" if trend == "up" else "top"
    return (f"{asset} ⚠️ The {what} you set was broken",
            f"{what.capitalize()}: {fmt(anchor, digits)} · Price: {fmt(price, digits)}\nBack to the automatic trend")


TEST_TITLE = "🔔 Test alert"
TEST_BODY = "If you received this notification, everything is working."
