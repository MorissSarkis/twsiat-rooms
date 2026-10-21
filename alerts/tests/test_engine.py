import os
import sys

import numpy as np
import pandas as pd

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from engine import AlertEngine, format_event  # noqa: E402
from levels import classic_pivots, detect_trend  # noqa: E402


def kinds(events):
    return [(e.kind, e.level_name) for e in events]


def run(engine, prices, lv, trend, atr=10.0, asset="GOLD"):
    out = []
    for p in prices:
        out += engine.evaluate(asset, p, lv, trend, atr)
    return out


def test_pivot_math():
    lv = classic_pivots(110, 90, 100, "d")
    assert lv.P == 100 and lv.R1 == 110 and lv.S1 == 90
    assert lv.R2 == 120 and lv.S2 == 80 and lv.R3 == 130 and lv.S3 == 70


def test_buy_ladder_full_sequence():
    lv = classic_pivots(110, 90, 100, "d")      # P100 S1 90 S2 80 S3 70
    eng = AlertEngine(approach_atr=0.1, rearm_atr=0.3, stop_buffer_atr=0.05)
    prices = [101, 99, 90.8, 90, 85, 80.5, 80, 75, 70.6, 70, 69.4]
    got = kinds(run(eng, prices, lv, "up"))
    assert got == [("PIVOT_DOWN", "P"), ("APPROACH", "S1"), ("TOUCH", "S1"),
                   ("APPROACH", "S2"), ("TOUCH", "S2"), ("APPROACH", "S3"),
                   ("TOUCH", "S3"), ("STOP", "S3")], got


def test_sell_ladder_and_no_buy_alerts_in_downtrend():
    lv = classic_pivots(110, 90, 100, "d")
    eng = AlertEngine()
    got = kinds(run(eng, [99, 101, 110, 85, 120, 131], lv, "down"))
    assert ("TOUCH", "R1") in got and ("TOUCH", "R2") in got and ("STOP", "R3") in got
    assert ("PIVOT_UP", "P") in got
    assert not any(k[1].startswith("S") for k in got)


def test_no_spam_when_chopping_around_level():
    lv = classic_pivots(110, 90, 100, "d")
    eng = AlertEngine(rearm_atr=0.3)  # rearm needs price > 93 (atr 10)
    got = kinds(run(eng, [95, 90, 91, 89.9, 91.5, 90, 92, 89], lv, "up"))
    assert got.count(("TOUCH", "S1")) == 1, got
    got2 = kinds(run(eng, [94, 90], lv, "up"))      # moved away > rearm, comes back
    assert got2.count(("TOUCH", "S1")) == 1, got2


def test_gap_through_s3_sends_stop_only():
    lv = classic_pivots(110, 90, 100, "d")
    eng = AlertEngine()
    got = kinds(run(eng, [75, 60], lv, "up"))
    assert ("STOP", "S3") in got and ("TOUCH", "S3") not in got, got


def test_range_trend_silent_by_default():
    lv = classic_pivots(110, 90, 100, "d")
    assert run(AlertEngine(), [101, 99, 89, 60], lv, "range") == []


def test_new_day_resets_state():
    eng = AlertEngine()
    lv1 = classic_pivots(110, 90, 100, "d1")
    lv2 = classic_pivots(110, 90, 100, "d2")
    assert kinds(run(eng, [95, 90], lv1, "up")).count(("TOUCH", "S1")) == 1
    assert kinds(run(eng, [95, 90], lv2, "up")).count(("TOUCH", "S1")) == 1


def zigzag(points, per_leg=6):
    closes = np.concatenate([np.linspace(a, b, per_leg, endpoint=False) for a, b in zip(points, points[1:])])
    closes = np.append(closes, points[-1])
    return pd.DataFrame({"open": closes, "high": closes + 0.2, "low": closes - 0.2, "close": closes})


def test_trend_detection():
    assert detect_trend(zigzag([100, 110, 104, 115, 108, 120, 112, 118])) == "up"
    assert detect_trend(zigzag([120, 110, 116, 105, 112, 100, 108, 102])) == "down"
    assert detect_trend(zigzag([100, 110, 100, 110, 100, 110, 100, 105])) == "range"


def test_message_format():
    lv = classic_pivots(2410, 2380, 2400, "d")
    eng = AlertEngine()
    e = run(eng, [2392, 2385, 2380], lv, "up")[-1]
    msg = format_event(e, lv)
    assert "GOLD" in msg and "BUY entry 1" in msg


# ---- client's trend rule: up while the long-term bottom holds ----
from levels import structure_trend  # noqa: E402


def test_structure_trend_bottom_and_break():
    up = zigzag([100, 110, 104, 115, 108, 120, 112, 125], per_leg=8)
    trend, bottom = structure_trend(up, k=3)
    assert trend == "up" and 107 <= bottom <= 113, (trend, bottom)
    broken = zigzag([100, 110, 104, 115, 108, 120, 112, 125, 118, 100], per_leg=8)
    trend2, top = structure_trend(broken, k=3)
    assert trend2 == "down" and top >= 124, (trend2, top)


def test_rebound_alert_after_touch():
    lv = classic_pivots(110, 90, 100, "d")
    eng = AlertEngine(approach_atr=0.1)
    got = kinds(run(eng, [95, 90, 89, 91.2], lv, "up"))
    assert ("REBOUND", "S1") in got, got


def test_trend_break_alert_stops_ladder():
    lv = classic_pivots(110, 90, 100, "d")
    eng = AlertEngine()
    out = []
    for p in [95, 89, 70]:
        out += eng.evaluate("GOLD", p, lv, "up", 10.0, anchor=66)
    got = kinds(out)
    assert ("TREND_BREAK", "BOTTOM") not in got
    got = kinds(eng.evaluate("GOLD", 65, lv, "up", 10.0, anchor=66))
    assert got == [("TREND_BREAK", "BOTTOM")], got


# ---- "all levels" mode, checked against the client's own MT5 charts (21 Oct 2026) ----
def test_levels_match_client_gold_chart():
    # yesterday's H/L/C implied by his chart lines
    lv = classic_pivots(4155.561, 4111.499, 4114.051, "2026-10-20")
    for got, want in [(lv.P, 4127.037), (lv.R1, 4142.575), (lv.R2, 4171.099),
                      (lv.S1, 4098.513), (lv.S2, 4082.975)]:
        assert abs(got - want) < 0.002, (got, want)


def test_all_mode_natural_gas_drop_today():
    lv = classic_pivots(3.3310, 3.2602, 3.3010, "d")   # P≈3.2974 S1≈3.2638 S2≈3.2263 as on his chart
    eng = AlertEngine(approach_atr=0.1)
    out = []
    for p in [3.31, 3.29, 3.27, 3.25, 3.23, 3.2049]:
        out += eng.evaluate_all("NATURAL GAS", p, lv, "up", 0.15)
    got = [(e.kind, e.side, e.level_name) for e in out if e.kind == "CROSS"]
    assert got == [("CROSS", "down", "P"), ("CROSS", "down", "S1"), ("CROSS", "down", "S2")], got


def test_all_mode_both_directions_and_no_trend_filter():
    lv = classic_pivots(110, 90, 100, "d")
    eng = AlertEngine()
    out = []
    for p in [95, 89, 95, 101, 111, 105]:          # trend says DOWN, still alerts S1 and rises
        out += eng.evaluate_all("X", p, lv, "down", 10.0, approach=False)
    got = [(e.side, e.level_name) for e in out]
    assert got == [("down", "S1"), ("up", "S1"), ("up", "P"), ("up", "R1"), ("down", "R1")], got


def test_all_mode_gap_through_several_levels_in_order():
    lv = classic_pivots(110, 90, 100, "d")
    eng = AlertEngine()
    out = eng.evaluate_all("X", 101, lv, "up", 10.0, approach=False)
    out += eng.evaluate_all("X", 75, lv, "up", 10.0, approach=False)
    assert [e.level_name for e in out] == ["P", "S1", "S2"]
    out = eng.evaluate_all("X", 115, lv, "up", 10.0, approach=False)
    assert [e.level_name for e in out] == ["S2", "S1", "P", "R1"]


def test_all_mode_wobble_at_level_is_silent():
    lv = classic_pivots(110, 90, 100, "d")      # S1 = 90, buffer = 0.5 with atr 10
    eng = AlertEngine(cross_buffer_atr=0.05)
    out = []
    for p in [95, 89.9, 90.1, 89.95, 90.2, 89.8, 95, 89]:
        out += eng.evaluate_all("X", p, lv, "up", 10.0, approach=False)
    got = [(e.side, e.level_name) for e in out]
    assert got == [("down", "S1"), ("down", "S1")], got   # first drop, then a real second drop after going back to 95


def test_arabic_messages_are_facts_only():
    from messages_ar import event_text
    lv = classic_pivots(4155.561, 4111.499, 4114.051, "d")
    out = []
    for trend in ("up", "down", "range"):
        eng = AlertEngine()
        for p in [4135, 4110, 4097, 4080, 4050, 4040, 4100, 4130, 4150, 4175, 4200]:
            out += eng.evaluate_all("GOLD", p, lv, trend, 60.0)
    texts = [" ".join(event_text(e, 2)[:2]) for e in out]
    assert texts
    for t in texts:
        for advice in ("شراء", "بيع", "جهّز", "إغلاق", "صفقات"):
            assert advice not in t, t


def test_first_look_is_silent_even_if_already_below_s3():
    lv = classic_pivots(110, 90, 100, "d")      # S3 = 70
    eng = AlertEngine()
    assert eng.evaluate_all("NG", 60, lv, "up", 10.0) == []          # was already broken before we started
    assert eng.evaluate_all("NG", 59, lv, "up", 10.0) == []          # still nothing new
    got = [(e.kind, e.level_name) for e in eng.evaluate_all("NG", 75, lv, "up", 10.0)]
    assert ("CROSS", "S3") in got                                    # a real new move does alert
