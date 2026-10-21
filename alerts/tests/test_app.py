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


def test_test_alert_lands_in_history_and_reaches_devices():
    svc, hub, c = make()
    sent = []
    hub.deliver = lambda item: sent.append(item)
    svc.sinks = [hub]
    c.post("/api/login", json={"password": "pw-123"})
    c.post("/api/test")
    assert sent and sent[0]["title"].startswith("🔔")
    assert c.get("/api/alerts").json()["alerts"][0]["kind"] == "test"


def test_muted_asset_not_pushed_but_kept_in_history():
    svc, hub, c = make()
    sent = []
    hub.deliver = lambda item: sent.append(item)
    svc.sinks = [hub]
    svc.update_settings(muted=["GOLD"])
    svc._emit("GOLD", "t", "b", "buy", "CROSS", "S1")
    svc._emit("EUR/USD", "t", "b", "buy", "CROSS", "S1")
    assert [i["asset"] for i in sent] == ["EUR/USD"]
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
