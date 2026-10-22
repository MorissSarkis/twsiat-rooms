"""access.Directory: code redeem, cache, paid end date, owner."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from access import Directory  # noqa: E402


def make(tmp_path, answers):
    d = Directory(str(tmp_path), url="http://x", key="k", token="t")
    calls = []

    def rpc(fn, payload):
        calls.append(fn)
        return answers(fn, payload)
    d._rpc = rpc
    return d, calls


def test_redeem_caches_and_owner_always_ok(tmp_path):
    acc = {"ok": True, "reason": "ib", "role": "client"}
    d, calls = make(tmp_path, lambda fn, p: {"user_id": "u1", "name": "Sami", "access": acc} if p.get("p_code") == "abc" else None)
    assert d.redeem("abc")["user_id"] == "u1"
    assert d.redeem("bad code!") is None and calls == ["alerts_redeem_code"]   # junk never reaches the db
    assert d.ok("u1") and d.info("u1")["name"] == "Sami" and not d.is_admin("u1")
    assert d.ok("owner") and d.is_admin("owner")
    d2 = Directory(str(tmp_path), url="http://x", key="k", token="t")          # survives a restart
    assert d2.ok("u1")


def test_paid_stops_at_end_date_without_waiting(tmp_path):
    d, _ = make(tmp_path, lambda fn, p: {})
    d._store("u2", {"ok": True, "reason": "paid", "until": "2001-01-01T00:00:00+00:00"})
    assert not d.ok("u2")
    d._store("u3", {"ok": True, "reason": "paid", "until": "2999-01-01T00:00:00Z"})
    assert d.ok("u3")


def test_refresh_and_unknown_user(tmp_path):
    d, calls = make(tmp_path, lambda fn, p: {u: {"ok": u == "a", "reason": "ib" if u == "a" else "none"} for u in p["p_ids"]})
    d.refresh(["a", "b", "owner"])
    assert d.ok("a") and not d.ok("b")
    assert not d.ok("c") and calls.count("alerts_check_users") == 2    # unknown -> asked once
