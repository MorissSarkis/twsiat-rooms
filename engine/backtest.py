"""Re-runs the Phase 1 backtest through engine/rules.py (parity check: the
production rules must give the same numbers as the research backtest).

Usage: python engine/backtest.py path/to/XAUUSDm_M5.csv
The CSV is the MT5 'Export Bars' format (tab separated, <DATE> <TIME> ...)."""
import sys
import numpy as np
import pandas as pd
import rules as R


def load_mt5_export(path):
    df = pd.read_csv(path, sep='\t')
    df.columns = [c.strip('<>').lower() for c in df.columns]
    df['t'] = pd.to_datetime(df.date + ' ' + df.time, format='%Y.%m.%d %H:%M:%S')
    df['spread'] = df.spread * 0.001  # gold: points -> price
    return df[['t', 'open', 'high', 'low', 'close', 'spread']].reset_index(drop=True)


def run(m5, digits=2):
    daily = R.daily_bars(m5)
    h1 = R.h1_trend(m5)
    T = m5.t.values; O = m5.open.values; H = m5.high.values; L = m5.low.values; SP = m5.spread.values
    out = []
    for day in daily.index:
        ctx = R.context_for(day, daily)
        if ctx is None or pd.isna(ctx.atr):
            continue
        i0 = np.searchsorted(T, np.datetime64(day))
        if i0 >= len(T):
            break
        sug = R.engine_suggestion(ctx, O[i0], digits=digits)
        if sug is None or not R.confirm_fill(sug.side, pd.Timestamp(T[i0]), h1):  # H1 checked when the suggestion is made
            continue
        buy = sug.side == 'BUY'
        lim = np.datetime64(sug.expires_at)
        j = i0; fill = None
        while j < len(T) and T[j] < lim:
            if buy and L[j] + SP[j] <= sug.entry: fill = j; break
            if (not buy) and H[j] >= sug.entry: fill = j; break
            j += 1
        if fill is None:
            continue
        res = R.track(sug.side, sug.entry, sug.stop_loss, sug.tp1, sug.tp2, m5, fill)
        out.append(dict(day=str(day.date()), side=sug.side, entry=sug.entry,
                        risk_usd_001=sug.risk_usd_001, **res))
    return pd.DataFrame(out)


if __name__ == '__main__':
    m5 = load_mt5_export(sys.argv[1])
    t = run(m5)
    t['y'] = t.day.str[:4]
    print('trades', len(t), 'trades/yr', round(len(t) / ((pd.Timestamp(t.day.iloc[-1]) - pd.Timestamp(t.day.iloc[0])).days / 365.25)))
    for col in ['result_r_partial', 'result_r_tp1only']:
        s = t[col]
        eq = s.cumsum(); dd = (eq.cummax() - eq).max()
        print(f"{col:18s} win%={(s > 0).mean() * 100:.1f} avgR={s.mean():+.3f} sumR={s.sum():+.1f} maxDD={dd:.1f}  "
              + ' '.join(f"{y[2:]}:{g[col].sum():+.0f}" for y, g in t.groupby('y')))
    t.to_csv('backtest_trades.csv', index=False)
