"""App tests: the service on simulated prices + the web API (login, state, settings, bottom/top)."""
import os
import sys
import tempfile

import yaml
from fastapi.testclient import TestClient

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from main import build  # noqa: E402

HERE = os.path.join(os.path.dirname(__file__), "..")


def make():
    with open(os.path.join(HERE, "config.yaml"), encoding="utf-8") as f:
        cfg = yaml.safe_load(f)
    cfg["feed"] = "demo"
    cfg["assets"] = cfg["assets"][:4] + [a for a in cfg["assets"] if a["name"] == "GOLD"]
    cfg["app"]["password"] = "pw-123"
    service, hub, app = build(cfg, tempfile.mkdtemp())
    for _ in range(3):
        service.step()
    return service, hub, TestClient(app)


def test_login_required_and_wrong_password():
    _, _, c = make()
    assert c.get("/api/state").status_code == 401
    assert c.get("/", follow_redirects=False).status_code == 302
    assert c.post("/api/login", json={"password": "nope"}).status_code == 401
    assert c.post("/api/login", json={"password": "pw-123"}).status_code == 200
    assert c.get("/").status_code == 200


def test_state_has_levels_trend_and_price():
    _, _, c = make()
    c.post("/api/login", json={"password": "pw-123"})
    st = c.get("/api/state").json()
    gold = next(a for a in st["assets"] if a["name"] == "GOLD")
    assert set(gold["levels"]) == {"R3", "R2", "R1", "P", "S1", "S2", "S3"}
    assert gold["price"] and gold["trend"] in ("up", "down", "range") and gold["nearest"]["level"]


def test_settings_mute_and_levels():
    svc, _, c = make()
    c.post("/api/login", json={"password": "pw-123"})
    r = c.post("/api/settings", json={"muted": ["GOLD", "NOT-AN-ASSET"], "levels": ["S1", "S2", "R1"], "approach": False})
    s = r.json()["settings"]
    assert s["muted"] == ["GOLD"] and s["levels"] == ["R1", "S1", "S2"] and s["approach"] is False


def test_manual_bottom_set_reject_and_clear():
    svc, _, c = make()
    c.post("/api/login", json={"password": "pw-123"})
    price = svc.prices["GOLD"]
    assert c.post("/api/override", json={"asset": "GOLD", "trend": "up", "anchor": price * 1.1}).status_code == 400
    assert c.post("/api/override", json={"asset": "GOLD", "trend": "up", "anchor": price * 0.9}).status_code == 200
    gold = next(a for a in c.get("/api/state").json()["assets"] if a["name"] == "GOLD")
    assert gold["manual"] and gold["trend"] == "up"
    c.post("/api/override/clear", json={"asset": "GOLD"})
    gold = next(a for a in c.get("/api/state").json()["assets"] if a["name"] == "GOLD")
    assert not gold["manual"]


def phones(hub, *uids):
    """register one fake phone per person; returns {uid: [items that rang]}"""
    rang = {u: [] for u in uids}
    for u in uids:
        hub.add({"endpoint": f"https://push.example/{u}", "keys": {"p256dh": "x", "auth": "y"}}, "", u)
    hub._send_one = lambda sub, data, urgency: rang[sub["uid"]].append(data)

    class Now:     # run sends inline
        def submit(self, fn, *a):
            fn(*a)
    hub.pool = Now()
    return rang


def test_test_alert_lands_in_history_and_reaches_devices():
    svc, hub, c = make()
    rang = phones(hub, "owner")
    c.post("/api/login", json={"password": "pw-123"})
    c.post("/api/test")
    assert rang["owner"] and rang["owner"][0]["title"].startswith("🔔")
    assert c.get("/api/alerts").json()["alerts"][0]["kind"] == "test"


def test_muted_asset_not_pushed_but_kept_in_history():
    svc, hub, c = make()
    rang = phones(hub, "owner")
    svc.update_settings(muted=["GOLD"])
    svc._emit("GOLD", "t", "b", "buy", "CROSS", "S1")
    svc._emit("EUR/USD", "t", "b", "buy", "CROSS", "S1")
    assert [i["tag"].split("-")[0] for i in rang["owner"]] == ["EUR/USD"]
    assert [h["asset"] for h in svc.history(2)] == ["EUR/USD", "GOLD"]


def test_gap_through_several_levels_is_one_message():
    from engine import Event
    from messages_ar import multi_cross_text
    evs = [Event("GOLD", "CROSS", "up", k, v, 4130.0, "up", "entry")
           for k, v in (("S3", 4054.45), ("S2", 4082.98), ("S1", 4098.51), ("P", 4127.04))]
    title, body, action, _ = multi_cross_text(evs, 2)
    assert "4 مستويات" in title and action == "up" and body.count("\n") == 5


def test_mt5_symbol_auto_detect_with_suffix():
    import pytest
    from service import AlertService

    class FakeMT5:
        known = {"USTECm", "DE30m", "XAUUSDm", "UK100"}
        def has_symbol(self, s):
            return s in self.known

    cfg = {"feed": "mt5", "mt5_suffix": "m", "assets": []}
    svc = AlertService(cfg, FakeMT5(), tempfile.mkdtemp())
    assert svc.symbol({"name": "NASDAQ 100", "mt5": ["NAS100", "USTEC"]}) == "USTECm"
    assert svc.symbol({"name": "DAX 40", "mt5": ["DE40", "DE30", "GER40"]}) == "DE30m"
    assert svc.symbol({"name": "GOLD", "mt5": "XAUUSD"}) == "XAUUSDm"
    assert svc.symbol({"name": "FTSE 100", "mt5": ["UK100"]}) == "UK100"      # broker without suffix
    with pytest.raises(RuntimeError):
        svc.symbol({"name": "SUGAR", "mt5": ["SUGAR", "SB"]})


def test_missing_symbol_does_not_stop_other_assets():
    from feeds import DemoFeed
    from service import AlertService

    class PartialFeed(DemoFeed):
        def has_symbol(self, s):
            return not s.startswith(("COFFEE", "KC"))

    cfg = {"feed": "mt5", "mt5_suffix": "m",
           "assets": [{"name": "COFFEE", "mt5": ["COFFEE", "KC"]}, {"name": "GOLD", "mt5": "XAUUSD"}]}
    svc = AlertService(cfg, PartialFeed(), tempfile.mkdtemp())
    svc.step()
    svc.step()
    assert "COFFEE" in svc.errors and "GOLD" in svc.prices


def test_daily_change_percent_in_state():
    _, _, c = make()
    c.post("/api/login", json={"password": "pw-123"})
    gold = next(a for a in c.get("/api/state").json()["assets"] if a["name"] == "GOLD")
    assert isinstance(gold["change_pct"], float)


# ---------- members: sign-in from rooms.twsiat.com, own settings, access ----------
class FakeDirectory:
    enabled = True

    def __init__(self):
        self.people = {"u-ib": {"ok": True, "reason": "ib", "role": "client", "name": "Sami"},
                       "u-paid": {"ok": True, "reason": "paid", "role": "client", "name": "Rami",
                                  "until": "2999-01-01T00:00:00+00:00"},
                       "u-boss": {"ok": True, "reason": "staff", "role": "manager", "name": "Boss"}}
        self.codes = {"code1": "u-ib", "code2": "u-paid", "code3": "u-boss", "code4": "u-old"}

    def redeem(self, code):
        uid = self.codes.pop(code, None)
        if uid is None:
            return None
        return {"user_id": uid, "name": self.info(uid).get("name"), "access": self.info(uid)}

    def info(self, uid):
        return self.people.get(uid, {"ok": False, "reason": "expired"})

    def ok(self, uid):
        return self.info(uid)["ok"]

    def is_admin(self, uid):
        return self.info(uid).get("role") in ("manager", "admin")


def make_members():
    from server import create_app
    svc, hub, _ = make()
    d = FakeDirectory()
    app = create_app(svc, hub, "pw-123", svc.dir, d, "https://rooms.example")
    return svc, hub, d, app


def member(app, code):
    c = TestClient(app)
    r = c.get(f"/auth?code={code}", follow_redirects=False)
    return c, r


def test_member_code_signs_in_once():
    _, _, _, app = make_members()
    c, r = member(app, "code1")
    assert r.status_code == 302 and r.headers["location"] == "/"
    assert c.get("/api/state").json()["me"]["reason"] == "ib"
    c2, r2 = member(app, "code1")                    # same link opened again right away (browser -> installed app)
    assert r2.status_code == 302 and c2.get("/api/state").json()["me"]["reason"] == "ib"
    import time as _t
    real = _t.time
    try:
        _t.time = lambda: real() + 300               # after 2 minutes the link is dead
        c3, r3 = member(app, "code1")
        assert r3.status_code == 400 and c3.get("/api/state").status_code == 401
    finally:
        _t.time = real


def test_dead_link_on_a_signed_in_phone_just_opens_the_app():
    _, _, _, app = make_members()
    c, _ = member(app, "code1")
    r = c.get("/auth?code=nope", follow_redirects=False)
    assert r.status_code == 302 and r.headers["location"] == "/"


def test_no_access_goes_to_expired_page():
    _, _, _, app = make_members()
    c, r = member(app, "code4")
    assert r.status_code == 302 and r.headers["location"] == "/expired"
    assert "rooms.example/alerts" in c.get("/expired").text


def test_each_member_has_own_settings_and_alerts():
    svc, hub, d, app = make_members()
    a, _ = member(app, "code1")
    b, _ = member(app, "code2")
    rang = phones(hub, "u-ib", "u-paid")
    svc.state["history"].clear()                     # ignore alerts the simulated prices made during setup
    a.post("/api/settings", json={"muted": ["GOLD"], "levels": ["S1"], "approach": False})
    assert b.get("/api/state").json()["settings"]["levels"] == list(("R3", "R2", "R1", "P", "S1", "S2", "S3"))
    svc._emit("GOLD", "t", "b", "down", "CROSS", "S1")
    svc._emit("EUR/USD", "t", "b", "down", "CROSS", "R2")
    svc._emit("EUR/USD", "t", "b", "info", "NEAR", "S1")
    assert len(rang["u-ib"]) == 0                    # GOLD muted, R2 not chosen, approach off
    assert len(rang["u-paid"]) == 3
    assert [x["asset"] for x in a.get("/api/alerts").json()["alerts"]] == ["GOLD"]   # muted stays in the list
    a.post("/api/test")
    assert len(rang["u-ib"]) == 1 and len(rang["u-paid"]) == 3     # test only to the sender
    assert all(x["kind"] != "test" for x in b.get("/api/alerts").json()["alerts"])


def test_expired_member_stops_ringing_and_is_sent_to_renew():
    svc, hub, d, app = make_members()
    c, _ = member(app, "code2")
    rang = phones(hub, "u-paid")
    svc._emit("EUR/USD", "t", "b", "down", "CROSS", "S1")
    d.people["u-paid"] = {"ok": False, "reason": "expired"}
    svc._emit("EUR/USD", "t", "b", "down", "CROSS", "S2")
    assert len(rang["u-paid"]) == 1
    assert c.get("/api/state").status_code == 403
    assert c.get("/", follow_redirects=False).headers["location"] == "/expired"


def test_only_team_sets_bottom_top():
    svc, hub, d, app = make_members()
    client, _ = member(app, "code1")
    boss, _ = member(app, "code3")
    price = svc.prices["GOLD"]
    body = {"asset": "GOLD", "trend": "up", "anchor": price * 0.9}
    assert client.post("/api/override", json=body).status_code == 403
    assert boss.post("/api/override", json=body).status_code == 200
    assert boss.get("/api/state").json()["me"]["admin"] is True
    assert client.get("/api/state").json()["me"]["admin"] is False


def test_old_password_sessions_still_work(tmp_path):
    import json
    from server import Sessions
    (tmp_path / "sessions.json").write_text(json.dumps({"tok": 9e12}))
    s = Sessions(str(tmp_path))
    assert s.uid("tok") == "owner"


def test_brief_database_hiccup_does_not_show_errors():
    svc, _, _ = make()
    assert not svc.errors
    real = svc.feed.price
    svc.feed.price = lambda s: (_ for _ in ()).throw(RuntimeError("database not reachable"))
    svc.step()
    assert not svc.errors                              # prices were fine seconds ago: stay quiet
    svc._last_ok = {k: 0 for k in svc._last_ok}        # ...but after 2 minutes of failures, show it
    svc.step()
    assert svc.errors
    svc.feed.price = real
    svc.step()
    assert not svc.errors


def test_each_member_gets_alerts_in_their_language():
    svc, hub, d, app = make_members()
    a, _ = member(app, "code1")
    b, _ = member(app, "code2")
    rang = phones(hub, "u-ib", "u-paid")
    svc.state["history"].clear()
    b.post("/api/settings", json={"lang": "en"})
    from engine import Event
    e = Event("GOLD", "CROSS", "down", "S1", 3970.78, 3970.5, "up", "entry")
    import messages_ar as AR, messages_en as EN
    t1, b1, act = AR.event_text(e, 2); te, be, _ = EN.event_text(e, 2)
    svc._emit("GOLD", t1, b1, act, "CROSS", "S1", {"en": {"title": te, "body": be}})
    assert "وصل" in rang["u-ib"][0]["title"] and "Support 1" in rang["u-paid"][0]["title"]
    assert "Price reached" in b.get("/api/alerts").json()["alerts"][0]["title"]
    assert "وصل" in a.get("/api/alerts").json()["alerts"][0]["title"]
    assert b.get("/api/state").json()["settings"]["lang"] == "en"


def test_crypto_shows_two_decimals():
    from service import AlertService
    svc = AlertService({"feed": "demo", "assets": []}, None, tempfile.mkdtemp())
    assert svc._digits({"group": "crypto"}, "SOLUSD", 101.17) == 2
    assert svc._digits({"group": "crypto"}, "XRPUSD", 2.48) == 4
    assert svc._digits({"group": "crypto", "digits": 3}, "SOLUSD", 101.17) == 3
