"""Arabic alert texts — facts only: where the price went. No buy/sell advice;
the trader decides what to do."""
from engine import fmt

TREND_AR = {"up": "صاعد ↗", "down": "هابط ↘", "range": "غير واضح ↔"}

LEVEL_AR = {
    "S1": "الدعم الأول", "S2": "الدعم الثاني", "S3": "الدعم الثالث",
    "R1": "المقاومة الأولى", "R2": "المقاومة الثانية", "R3": "المقاومة الثالثة",
    "P": "نقطة الارتكاز",
}


def _lvl(code):
    return f"{LEVEL_AR.get(code, code)} {code}"


def event_text(e, digits=None):
    """Returns (title, body, action). action = down / up / break / info (used for colour only)."""
    f = lambda v: fmt(v, digits)
    trend = f"الميل العام: {TREND_AR.get(e.trend, e.trend)}"
    if e.kind == "CROSS":
        if e.level_name == "P":
            way, arrow = ("نزولاً", "📉") if e.side == "down" else ("صعوداً", "📈")
            title = f"{e.asset} {arrow} السعر تخطى نقطة الارتكاز {way}"
        else:
            arrow = "📉" if e.side == "down" else "📈"
            title = f"{e.asset} {arrow} السعر وصل {_lvl(e.level_name)}"
        body = f"{LEVEL_AR.get(e.level_name)}: {f(e.level)} · السعر: {f(e.price)}\n{trend}"
        return title, body, e.side
    if e.kind == "NEAR":
        verb = "ينخفض باتجاه" if e.side == "down" else "يرتفع باتجاه"
        title = f"{e.asset} ⏳ السعر {verb} {_lvl(e.level_name)}"
        body = f"{LEVEL_AR.get(e.level_name)}: {f(e.level)} · السعر: {f(e.price)}\n{trend}"
        return title, body, "info"
    if e.kind == "STOP":
        title = f"{e.asset} ⚠️ السعر كسر {_lvl(e.level_name)}"
        body = f"{LEVEL_AR.get(e.level_name)}: {f(e.level)} · السعر: {f(e.price)}\n{trend}"
        return title, body, "break"
    return f"{e.asset} {e.kind}", f"{e.level_name} {f(e.level)} · {f(e.price)}", "info"


def trend_change_text(asset, prev, new, anchor, digits=None):
    title = f"{asset} 🔄 تغيّر الميل العام"
    body = f"صار {TREND_AR.get(new, new)} (كان {TREND_AR.get(prev, prev)})"
    if anchor is not None and new in ("up", "down"):
        body += f"\n{'القاع' if new == 'up' else 'القمة'}: {fmt(anchor, digits)}"
    return title, body


def multi_cross_text(events, digits=None):
    """Price jumped through several levels at once (gap / news): one message instead of many."""
    f = lambda v: fmt(v, digits)
    e0 = events[0]
    up = e0.side == "up"
    names = "، ".join(_lvl(e.level_name) for e in events)
    title = f"{e0.asset} {'📈' if up else '📉'} السعر {'ارتفع' if up else 'انخفض'} بقوة وتخطى {len(events)} مستويات"
    lines = [f"{LEVEL_AR.get(e.level_name)}: {f(e.level)}" for e in events]
    body = "\n".join(lines) + f"\nالسعر: {f(events[-1].price)}\nالميل العام: {TREND_AR.get(e0.trend, e0.trend)}"
    return title, body, e0.side, names
