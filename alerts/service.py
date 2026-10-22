"""The alert service: polls prices, runs the engine, keeps everything the app shows,
and hands each alert to the delivery channels (phone push, optionally Telegram/WhatsApp)."""
import json
import logging
import os
import threading
import time
import uuid
from datetime import datetime, timezone

from engine import AlertEngine, fmt
from levels import atr, levels_from_daily, structure_trend
from messages_ar import TREND_AR, event_text, multi_cross_text, trend_change_text

log = logging.getLogger("service")
LEVELS = ("R3", "R2", "R1", "P", "S1", "S2", "S3")


def _now_iso():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


class AlertService:
    def __init__(self, cfg, feed, data_dir, sinks=None):
        self.cfg, self.feed, self.dir = cfg, feed, data_dir
        self.sinks = sinks or []
        self.lock = threading.RLock()
        self.state_file = os.path.join(data_dir, "state.json")
        self.state = self._load()
        self.engine = AlertEngine(cfg.get("approach_atr", 0.10), cfg.get("rearm_atr", 0.30),
                                  cfg.get("stop_buffer_atr", 0.05), cfg.get("alert_without_trend", False),
                                  state=self.state["engine"],
                                  cross_buffer_atr=cfg.get("cross_buffer_atr", 0.15))
        self.contexts, self.prices, self.errors = {}, {}, {}
        self.last_poll = None
        self.assets = cfg["assets"]
        self.feed_name = cfg.get("feed", "mt5")
        self._resolved = {}
        self._retry_at = {}

    # ---------- persistence ----------
    def _load(self):
        try:
            with open(self.state_file, encoding="utf-8") as f:
                s = json.load(f)
        except Exception:
            s = {}
        for k in ("engine", "overrides", "last_trend", "settings", "users"):
            s.setdefault(k, {})
        s.setdefault("history", [])
        self._defaults(s["settings"])          # "settings" = the owner (password login), as before
        return s

    def _defaults(self, st):
        st.setdefault("muted", [])
        st.setdefault("levels", list(self.cfg.get("levels", LEVELS)))
        st.setdefault("approach", bool(self.cfg.get("approach_alerts", True)))
        return st

    # ---------- each person's own choices ----------
    def user_settings(self, uid="owner"):
        with self.lock:
            if uid in (None, "", "owner"):
                return self.state["settings"]
            return self._defaults(self.state["users"].setdefault(uid, {}))

    def visible(self, uid, item):
        """Does this alert belong in this person's list? (their levels / approach choice; tests only to the sender)"""
        if item.get("kind") == "test":
            return item.get("to", "owner") == (uid or "owner")
        s = self.user_settings(uid)
        if item.get("kind") == "NEAR" and not s["approach"]:
            return False
        lv = item.get("level")
        if item.get("kind") in ("CROSS", "NEAR", "STOP") and lv and not any(x in s["levels"] for x in str(lv).split(",")):
            return False
        return True

    def wants(self, uid, item):
        """...and should it ring their phone? (muted assets stay in the list but are silent)"""
        if item.get("kind") != "test" and item.get("asset") in self.user_settings(uid)["muted"]:
            return False
        return self.visible(uid, item)

    def save(self):
        with self.lock:
            tmp = self.state_file + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(self.state, f, ensure_ascii=False)
            os.replace(tmp, self.state_file)

    # ---------- helpers ----------
    def symbol(self, a):
        if self.feed_name == "demo":
            return a["name"]
        if self.feed_name not in ("mt5", "supabase"):
            return a.get(self.feed_name, a["name"])
        if a["name"] in self._resolved:
            return self._resolved[a["name"]]
        names = a.get("mt5", a["name"])
        names = names if isinstance(names, list) else [names]
        # the database stores the bridge's names without the broker suffix (XAUUSD, not XAUUSDm)
        suffix = str(self.cfg.get("mt5_suffix", "") or "") if self.feed_name == "mt5" else ""
        candidates = [n + suffix for n in names] + ([n for n in names] if suffix else [])
        has = getattr(self.feed, "has_symbol", None)
        for c in candidates:
            if has is None or has(c):
                self._resolved[a["name"]] = c
                log.info("%s -> %s", a["name"], c)
                return c
        if self.feed_name == "supabase":
            raise RuntimeError("no prices yet: the price bridge is not sending " + " / ".join(candidates))
        raise RuntimeError("not available at this broker (tried " + ", ".join(candidates) + ")")

    def effective_trend(self, name):
        o = self.state["overrides"].get(name)
        ctx = self.contexts.get(name)
        if o:
            return o["trend"], o["anchor"], True
        if ctx:
            return ctx["auto_trend"], ctx["auto_anchor"], False
        return "range", None, False

    def _context(self, sym):
        daily = self.feed.daily(sym, 40)
        tbars = self.feed.bars(sym, self.cfg.get("trend_timeframe", "D1"), 500)
        trend, anchor = structure_trend(tbars, self.cfg.get("swing_strength", 5))
        return {"levels": levels_from_daily(daily), "atr": atr(daily, 14), "auto_trend": trend,
                "prev_close": float(daily["close"].iloc[-1]),
                "auto_anchor": anchor, "digits": self.feed.digits(sym), "at": time.time()}

    def _emit(self, asset, title, body, action, kind, level=None, extra=None):
        item = {"id": uuid.uuid4().hex[:12], "ts": _now_iso(), "asset": asset, "title": title,
                "body": body, "action": action, "kind": kind, "level": level}
        if extra:
            item.update(extra)
        with self.lock:
            h = self.state["history"]
            if kind == "test":     # keep only each person's latest test, so tests never push real alerts out
                h[:] = [i for i in h if not (i.get("kind") == "test" and i.get("to", "owner") == item.get("to", "owner"))]
            h.insert(0, item)
            del h[self.cfg.get("history_size", 1000):]
        for s in self.sinks:
            # the phone hub filters per person; other channels (Telegram) follow the owner's choices
            if not getattr(s, "per_user", False) and not self.wants("owner", item):
                continue
            try:
                s.deliver(item)
            except Exception as ex:
                log.error("delivery via %s failed: %s", type(s).__name__, ex)
        return item

    # ---------- one polling round ----------
    def step(self):
        refresh = self.cfg.get("refresh_minutes", 15) * 60
        mode = self.cfg.get("mode", "all")
        for a in self.assets:
            name, sym = a["name"], None
            try:
                sym = self.symbol(a)
                ctx = self.contexts.get(name)
                if ctx is None or time.time() - ctx["at"] > refresh:
                    if ctx is None and time.time() < self._retry_at.get(name, 0):
                        continue                         # failed recently: try again in a minute
                    try:
                        ctx = self._context(sym)
                    except Exception:
                        self._retry_at[name] = time.time() + 60
                        raise
                    with self.lock:
                        self.contexts[name] = ctx
                    prev = self.state["last_trend"].get(name)
                    if prev and prev != ctx["auto_trend"] and name not in self.state["overrides"]:
                        t, b = trend_change_text(name, prev, ctx["auto_trend"], ctx["auto_anchor"], ctx["digits"])
                        self._emit(name, t, b, "info", "TREND")
                    self.state["last_trend"][name] = ctx["auto_trend"]
                price = self.feed.price(sym)
                with self.lock:
                    self.prices[name] = price
                self.errors.pop(name, None)
                trend, anchor, manual = self.effective_trend(name)
                if mode == "all":
                    # every level for everyone; each person's choices are applied on delivery
                    events = self.engine.evaluate_all(name, price, ctx["levels"], trend, ctx["atr"], LEVELS, True)
                else:
                    events = self.engine.evaluate(name, price, ctx["levels"], trend, ctx["atr"], anchor)
                crosses = [e for e in events if e.kind == "CROSS"]
                if len(crosses) > 1:   # jumped several levels in one go -> one combined message
                    title, body, action, _ = multi_cross_text(crosses, ctx["digits"])
                    self._emit(name, title, body, action, "CROSS", ",".join(e.level_name for e in crosses),
                               {"price": price, "side": crosses[0].side})
                    events = [e for e in events if e.kind != "CROSS"]
                for e in events:
                    title, body, action = event_text(e, ctx["digits"])
                    self._emit(name, title, body, action, e.kind, e.level_name,
                               {"price": price, "level_price": e.level, "side": e.side})
                    log.info("ALERT %s %s %s @ %s", name, e.kind, e.level_name, price)
                # manual bottom/top broken -> tell him and fall back to automatic
                if manual and ((trend == "up" and price < anchor) or (trend == "down" and price > anchor)):
                    self.state["overrides"].pop(name, None)
                    what = "القاع" if trend == "up" else "القمة"
                    self._emit(name, f"{name} ⚠️ انكسر {what} اللي حددته",
                               f"{what}: {fmt(anchor, ctx['digits'])} · السعر: {fmt(price, ctx['digits'])}\n"
                               f"رجعنا للميل العام التلقائي", "break", "TREND")
            except Exception as ex:
                if self.errors.get(name) != str(ex):      # log each problem once, not every 30 seconds
                    log.warning("%s (%s): %s", name, sym, ex)
                self.errors[name] = str(ex)
        self.last_poll = _now_iso()
        self.save()

    def run_forever(self, stop_event=None):
        poll = self.cfg.get("poll_seconds", 30)
        while not (stop_event and stop_event.is_set()):
            t0 = time.time()
            try:
                self.step()
            except Exception:                  # never let one bad round stop the alerts
                log.exception("polling round failed, continuing")
            time.sleep(max(1.0, poll - (time.time() - t0)))

    # ---------- what the app reads ----------
    def snapshot(self, uid="owner"):
        out = []
        settings = self.user_settings(uid)
        with self.lock:
            for a in self.assets:
                name = a["name"]
                ctx, price = self.contexts.get(name), self.prices.get(name)
                qt = getattr(self.feed, "quote_time", None)
                item = {"name": name, "group": a.get("group", ""), "price": price,
                        "quote_t": qt(self._resolved[name]) if qt and name in self._resolved else None,
                        "muted": name in settings["muted"],
                        "error": self.errors.get(name)}
                if ctx:
                    trend, anchor, manual = self.effective_trend(name)
                    lv = ctx["levels"]
                    levels = {k: getattr(lv, k) for k in LEVELS}
                    item.update({"levels": levels, "day": lv.day, "trend": trend,
                                 "trend_ar": TREND_AR.get(trend, trend), "anchor": anchor,
                                 "manual": manual, "digits": ctx["digits"], "atr": ctx["atr"]})
                    if price is not None and ctx.get("prev_close"):
                        item["change"] = price - ctx["prev_close"]
                        item["change_pct"] = 100.0 * (price / ctx["prev_close"] - 1.0)
                    if price is not None:
                        near = min(levels.items(), key=lambda kv: abs(kv[1] - price))
                        item["nearest"] = {"level": near[0], "value": near[1],
                                           "distance": price - near[1],
                                           "atr_frac": abs(price - near[1]) / ctx["atr"] if ctx["atr"] else None}
                        above = [k for k in LEVELS if levels[k] > price]
                        item["zone"] = f"{above[-1]}" if above else "above R3"
                out.append(item)
        return {"assets": out, "last_poll": self.last_poll, "settings": settings}

    def history(self, limit=200, uid="owner"):
        with self.lock:
            items = list(self.state["history"])
        return [i for i in items if self.visible(uid, i)][:limit]

    # ---------- changes from the app ----------
    def set_override(self, name, trend, anchor):
        price = self.prices.get(name)
        if price is not None and ((trend == "up" and price < anchor) or (trend == "down" and price > anchor)):
            raise ValueError("السعر الحالي كاسر هذا المستوى")
        with self.lock:
            self.state["overrides"][name] = {"trend": trend, "anchor": float(anchor)}
        self.save()

    def clear_override(self, name):
        with self.lock:
            self.state["overrides"].pop(name, None)
        self.save()

    def update_settings(self, muted=None, levels=None, approach=None, uid="owner"):
        s = self.user_settings(uid)
        with self.lock:
            if muted is not None:
                s["muted"] = [m for m in muted if any(a["name"] == m for a in self.assets)]
            if levels is not None:
                s["levels"] = [l for l in LEVELS if l in levels]
            if approach is not None:
                s["approach"] = bool(approach)
        self.save()
