"""Replay history: which alerts WOULD have fired over the last N days.
Use it to show the client the logic on real past moves before going live.

    python replay.py GOLD --days 10
    python replay.py "EUR/USD" --days 5 --feed yahoo
    python replay.py GOLD --feed demo
"""
import argparse
import os
import sys

import pandas as pd
import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from engine import AlertEngine  # noqa: E402
from feeds import make_feed  # noqa: E402
from levels import atr, levels_from_daily, structure_trend  # noqa: E402

TF_STEP = {"H1": pd.Timedelta(hours=1), "H4": pd.Timedelta(hours=4), "D1": pd.Timedelta(days=1)}


def bar_path(o, h, l, c):
    """Approximate tick order inside a bar."""
    return [o, l, h, c] if c >= o else [o, h, l, c]


def replay(feed, name, sym, cfg, days):
    m5 = feed.intraday_history(sym, "M5", 6000)
    daily = feed.daily(sym, 120)
    tf = cfg.get("trend_timeframe", "D1")
    tbars = feed.bars(sym, tf, 800)
    step = TF_STEP.get(tf, pd.Timedelta(hours=4))

    start = m5.index[-1].normalize() - pd.Timedelta(days=days - 1)
    m5 = m5[m5.index >= start]
    eng = AlertEngine(cfg.get("approach_atr", 0.10), cfg.get("rearm_atr", 0.30),
                      cfg.get("stop_buffer_atr", 0.05), cfg.get("alert_without_trend", False),
                      cross_buffer_atr=cfg.get("cross_buffer_atr", 0.15))
    rows, cache = [], {}
    for ts, bar in m5.iterrows():
        dkey = ts.normalize()
        if dkey not in cache:
            prev_days = daily[daily.index.normalize() < dkey]
            if len(prev_days) < 15:
                continue
            cache[dkey] = (levels_from_daily(prev_days), atr(prev_days, 14))
        lv, a = cache[dkey]
        n_done = int((tbars.index + step <= ts).sum())
        if n_done not in cache:
            cache[n_done] = structure_trend(tbars.iloc[:n_done], cfg.get("swing_strength", 5))
        trend, anchor = cache[n_done]
        for px in bar_path(bar["open"], bar["high"], bar["low"], bar["close"]):
            if cfg.get("mode", "all") == "all":
                evs = eng.evaluate_all(name, float(px), lv, trend, a, cfg.get("levels", AlertEngine.LEVEL_ORDER),
                                       cfg.get("approach_alerts", True))
            else:
                evs = eng.evaluate(name, float(px), lv, trend, a, anchor)
            for e in evs:
                rows.append({"time": ts, "trend": trend, "anchor": round(anchor, 5) if anchor else None, "alert": e.kind, "dir": e.side, "level": e.level_name,
                             "level_price": round(e.level, 5), "price": round(e.price, 5)})
    return pd.DataFrame(rows)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    ap.add_argument("asset", help="asset name from config.yaml, e.g. GOLD")
    ap.add_argument("--days", type=int, default=10)
    ap.add_argument("--feed", choices=["mt5", "yahoo", "demo"])
    ap.add_argument("--config", default=os.path.join(here, "config.yaml"))
    ap.add_argument("--csv", help="save results to this CSV file")
    args = ap.parse_args()
    with open(args.config, encoding="utf-8") as f:
        cfg = yaml.safe_load(f)
    feed_name = args.feed or cfg.get("feed", "mt5")
    a = next((x for x in cfg["assets"] if x["name"].lower() == args.asset.lower()), None)
    if a is None:
        sys.exit(f"Asset '{args.asset}' not in config.yaml")
    sym = a["name"] if feed_name == "demo" else a.get(feed_name, a.get("mt5"))
    df = replay(make_feed(feed_name, cfg), a["name"], sym, cfg, args.days)
    if df.empty:
        print("No alerts would have fired in this period.")
        return
    pd.set_option("display.width", 160)
    print(df.to_string(index=False))
    print(f"\n{len(df)} alerts over {args.days} days")
    if args.csv:
        df.to_csv(args.csv, index=False)
        print(f"Saved to {args.csv}")


if __name__ == "__main__":
    main()
