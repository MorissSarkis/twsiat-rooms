"""Backtest of engine v2 (engine/rules2.py) on Exness M5 bars, spread included.

Usage: python engine/backtest2.py path/to/XAUUSDm_M5.csv [--all-hours] [--limit-hours N]
  default       market entry at the signal bar close, signals 12:00–20:00 GMT only
  --all-hours   also report signals outside the tested hours (flagged in production)
  --limit-hours entry as a limit order at the signal price, valid N hours (simulates admin approval)
"""
import sys
import numpy as np
import pandas as pd
import rules2 as R2
from backtest import load_mt5_export


def run(m5, limit_hours=None, all_hours=False, digits=2):
    h1 = R2.build_h1(m5)
    d1, h4 = R2.trend_series(m5)
    T = m5.t.values; H = m5.high.values; L = m5.low.values; C = m5.close.values; SP = m5.spread.values
    out = []
    busy_until = np.datetime64('1970-01-01')
    day_key = None; day_count = 0; lv = None; lv_key = None
    for bt, bar in h1.iterrows():
        t = bt + pd.Timedelta(hours=1)                         # signal time = bar close
        ds = R2.ny_day_start(t)
        if ds != lv_key:
            lv = R2.pivots_for(ds, h1); lv_key = ds
        if ds != day_key:
            day_key = ds; day_count = 0
        if np.datetime64(t) < busy_until or day_count >= R2.CONFIG2['max_per_day']:
            continue
        tested = R2.in_tested_hours(t)
        if not tested and not all_hours:
            continue
        if t.dayofweek == 4 and t.hour >= R2.CONFIG2['friday_last_signal_hour']:
            continue
        sig = R2.signal_at(bar, lv, R2.trend_at(t, d1, h4), digits)
        if sig is None:
            continue
        i0 = np.searchsorted(T, np.datetime64(t))
        if i0 >= len(T):
            break
        buy = sig['side'] == 'BUY'
        fill = None
        if limit_hours is None:
            fill = i0
        else:
            lim = np.datetime64(t + pd.Timedelta(hours=limit_hours))
            j = i0
            while j < len(T) and T[j] < lim:
                if buy and L[j] + SP[j] <= sig['entry']: fill = j; break
                if (not buy) and H[j] >= sig['entry']: fill = j; break
                j += 1
        day_count += 1
        if fill is None:
            out.append(dict(t=t, tested=tested, filled=False, **sig)); continue
        res = R2.track2(sig['side'], sig['entry'], sig['stop_loss'], sig['tp1'], sig['tp2'], T, H, L, C, SP, fill)
        busy_until = np.datetime64(res['closed_at'])
        out.append(dict(t=t, tested=tested, filled=True, **sig, **res))
    return pd.DataFrame(out)


def report(t, label):
    f = t[t.filled]
    if f.empty:
        print(label, 'no trades'); return
    s = f.r_partial
    eq = s.cumsum(); dd = (eq.cummax() - eq).max()
    yrs = (f.t.iloc[-1] - f.t.iloc[0]).days / 365.25
    is_ = f[f.t < '2024-01-01'].r_partial; oos = f[f.t >= '2024-01-01'].r_partial
    print(f"{label}: trades {len(f)} ({len(f)/yrs:.0f}/yr) win%={(s > 0).mean()*100:.1f} "
          f"TP1%={f.tp1_hit.mean()*100:.1f} avgR={s.mean():+.3f} sumR={s.sum():+.1f} maxDD={dd:.1f}R | "
          f"2020-23 {is_.mean():+.3f} ({len(is_)}) 2024-26 {oos.mean():+.3f} ({len(oos)}) | TP1-only avg {f.r_tp1only.mean():+.3f}")
    print('   by year:', ' '.join(f"{y}:{g.r_partial.sum():+.0f}" for y, g in f.groupby(f.t.dt.year)))


if __name__ == '__main__':
    args = sys.argv[1:]
    path = args[0]
    lh = float(args[args.index('--limit-hours') + 1]) if '--limit-hours' in args else None
    m5 = load_mt5_export(path)
    t = run(m5, limit_hours=lh)
    t.to_csv('backtest2_trades.csv', index=False)
    report(t, 'TESTED HOURS 12-20')
    if lh is not None:
        print(f"   limit fill rate: {t.filled.mean()*100:.1f}%")
    if '--all-hours' in args:
        a = run(m5, limit_hours=lh, all_hours=True)
        report(a, 'ALL HOURS (24h)')
        f = a[a.filled]
        print('   avgR by signal hour:', ' '.join(f"{h}:{g.r_partial.mean():+.2f}({len(g)})" for h, g in f.groupby(f.t.dt.hour)))
