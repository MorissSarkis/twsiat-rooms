"""Supabase feed: live price when fresh, last M5 close when not, daily bars without today."""
import os
import sys
from datetime import datetime, timedelta, timezone

import pandas as pd
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from feeds import SupabaseFeed  # noqa: E402

NOW = datetime.now(timezone.utc).replace(microsecond=0)


def iso(dt):
    return dt.isoformat()


class FakeFeed(SupabaseFeed):
    def __init__(self, live_age_s, m5_age_s=300, with_live=True):
        os.environ.update(SUPABASE_URL="http://x", SUPABASE_PUBLISHABLE_KEY="k", ALERTS_TOKEN="t")
        super().__init__({"poll_seconds": 10, "supabase": {"live_max_age_seconds": 120}})
        self.calls = []
        self.live_age_s, self.m5_age_s, self.with_live = live_age_s, m5_age_s, with_live

    def _rpc_once(self, fn, payload):
        self.calls.append(fn)
        if fn == "alerts_symbols":
            return {"XAUUSD": 2, "EURGBP": None}
        if fn == "alerts_feed":
            live = {"XAUUSD": [4133.25, iso(NOW - timedelta(seconds=self.live_age_s))]} if self.with_live else {}
            return {"now": iso(NOW), "live": live,
                    "m5": {"XAUUSD": [4130.0, iso(NOW - timedelta(seconds=self.m5_age_s))]}}
        if fn == "alerts_daily":
            today = NOW.date()
            hist = [[str(today - timedelta(days=d)), 1, 2, 0.5, 1.5] for d in range(25, 1, -1)]
            return hist + [[str(today - timedelta(days=1)), 4130, 4155.561, 4111.499, 4114.051],
                           [str(today), 4114, 4135, 4110, 4130]]
        raise AssertionError(fn)


def test_fresh_live_price_is_used():
    f = FakeFeed(live_age_s=5)
    assert f.price("XAUUSD") == 4133.25


def test_stale_live_falls_back_to_newer_m5_close():
    f = FakeFeed(live_age_s=3600, m5_age_s=300)
    assert f.price("XAUUSD") == 4130.0


def test_no_live_table_yet_uses_m5():
    f = FakeFeed(live_age_s=0, with_live=False)
    assert f.price("XAUUSD") == 4130.0


def test_symbols_and_digits():
    f = FakeFeed(live_age_s=5)
    assert f.has_symbol("XAUUSD") and f.has_symbol("EURGBP") and not f.has_symbol("XAGUSD")
    assert f.digits("XAUUSD") == 2 and f.digits("EURGBP") is None


def test_daily_excludes_today_and_is_cached():
    f = FakeFeed(live_age_s=5)
    d = f.daily("XAUUSD", 40)
    assert d.iloc[-1]["high"] == pytest.approx(4155.561)
    assert d.index[-1] < pd.Timestamp(NOW.date())
    f.daily("XAUUSD", 40)
    assert f.calls.count("alerts_daily") == 1


def test_one_feed_request_serves_many_symbols():
    f = FakeFeed(live_age_s=5)
    for _ in range(5):
        f.price("XAUUSD")
    assert f.calls.count("alerts_feed") == 1


def test_missing_settings_fail_clearly():
    for k in ("SUPABASE_URL", "SUPABASE_PUBLISHABLE_KEY", "ALERTS_TOKEN"):
        os.environ.pop(k, None)
    with pytest.raises(RuntimeError, match="ALERTS_TOKEN"):
        SupabaseFeed({})


def test_outage_fails_fast_instead_of_once_per_instrument():
    f = FakeFeed(live_age_s=5)
    n = {"calls": 0}

    def down(fn, payload):
        n["calls"] += 1
        raise ConnectionError("timeout")
    f._rpc_once = down
    for _ in range(57):
        with pytest.raises(Exception):
            f.has_symbol("XAUUSD")
    assert n["calls"] == 1


def test_old_patchy_history_is_not_used_as_yesterday():
    f = FakeFeed(live_age_s=5)
    today = NOW.date()
    old = [[str(today - timedelta(days=60 + i)), 0.86, 0.861, 0.85, 0.855] for i in range(20)]
    f._rpc_once = lambda fn, p: old if fn == "alerts_daily" else FakeFeed._rpc_once(f, fn, p)
    with pytest.raises(RuntimeError, match="history loading"):
        f.daily("EURGBP", 40)


def test_weekend_gap_is_fine():
    f = FakeFeed(live_age_s=5)
    today = NOW.date()
    rows = [[str(today - timedelta(days=3 + i)), 1, 2, 0.5, 1.5] for i in range(30)][::-1]
    f._rpc_once = lambda fn, p: rows if fn == "alerts_daily" else FakeFeed._rpc_once(f, fn, p)
    assert len(f.daily("XAUUSD", 40)) == 30
