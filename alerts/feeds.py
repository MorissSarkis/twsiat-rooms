"""Price data sources. All return lowercase open/high/low/close DataFrames
indexed by bar open time, containing COMPLETED bars only."""
import os
import time

import numpy as np
import pandas as pd
import requests

AGG = {"open": "first", "high": "max", "low": "min", "close": "last"}


class MT5Feed:
    """Reads prices straight from the MetaTrader 5 terminal (Windows).
    The terminal must be open and logged in to the broker account; levels then
    match exactly what the client sees on his charts."""

    def __init__(self, cfg=None):
        import MetaTrader5 as mt5
        self.mt5 = mt5
        if not mt5.initialize():
            raise RuntimeError(f"MT5 initialize failed: {mt5.last_error()}")
        self._selected = set()
        self.tf = {"M5": mt5.TIMEFRAME_M5, "M15": mt5.TIMEFRAME_M15, "H1": mt5.TIMEFRAME_H1,
                   "H4": mt5.TIMEFRAME_H4, "D1": mt5.TIMEFRAME_D1}

    def _rates(self, sym, tf, n, start=1):
        self.mt5.symbol_select(sym, True)
        r = self.mt5.copy_rates_from_pos(sym, self.tf[tf], start, n)
        if r is None or len(r) == 0:
            raise RuntimeError(f"No {tf} data for {sym}: {self.mt5.last_error()}")
        df = pd.DataFrame(r)
        df.index = pd.to_datetime(df["time"], unit="s")
        return df[["open", "high", "low", "close"]]

    def daily(self, sym, n=40):
        return self._rates(sym, "D1", n)            # start=1 skips today's open bar

    def bars(self, sym, tf, n=300):
        return self._rates(sym, tf, n)

    def intraday_history(self, sym, tf="M5", n=2000):
        return self._rates(sym, tf, n, start=0)

    def price(self, sym):
        # The symbol must be in Market Watch for MT5 to stream its price.
        first_time = sym not in self._selected
        if first_time:
            self.mt5.symbol_select(sym, True)
            self._selected.add(sym)
        for _ in range(3 if first_time else 1):
            t = self.mt5.symbol_info_tick(sym)
            if t is not None and t.bid > 0:
                return float(t.bid)
            if first_time:
                time.sleep(0.3)                # just added to Market Watch: give MT5 a moment
        # Still no live tick (e.g. market closed): use the close of the latest 1-minute candle.
        r = self.mt5.copy_rates_from_pos(sym, self.mt5.TIMEFRAME_M1, 0, 1)
        if r is not None and len(r):
            return float(r[0]["close"])
        raise RuntimeError(f"No price for {sym}")

    def digits(self, sym):
        info = self.mt5.symbol_info(sym)
        return info.digits if info else None

    def has_symbol(self, sym):
        return self.mt5.symbol_info(sym) is not None


class YahooFeed:
    """Free Yahoo Finance data. Good for testing; prices come from futures/spot
    markets and may be delayed, so levels can differ slightly from a broker's CFD."""

    def __init__(self, cfg=None):
        import yfinance as yf
        self.yf = yf

    def _hist(self, sym, period, interval):
        df = self.yf.Ticker(sym).history(period=period, interval=interval, auto_adjust=False)
        if df.empty:
            raise RuntimeError(f"No {interval} data for {sym}")
        df = df.rename(columns=str.lower)[["open", "high", "low", "close"]]
        return df

    def daily(self, sym, n=40):
        df = self._hist(sym, "3y", "1d")
        today = pd.Timestamp.now(tz=df.index.tz).normalize()
        return df[df.index < today].tail(n)

    def bars(self, sym, tf, n=300):
        if tf == "D1":
            return self.daily(sym, n)
        if tf in ("H1", "H4"):
            df = self._hist(sym, "60d", "1h")
            if tf == "H4":
                df = df.resample("4h").agg(AGG).dropna()
                step = pd.Timedelta(hours=4)
            else:
                step = pd.Timedelta(hours=1)
        else:
            df = self._hist(sym, "30d", "15m" if tf == "M15" else "5m")
            step = pd.Timedelta(minutes=15 if tf == "M15" else 5)
        now = pd.Timestamp.now(tz=df.index.tz)
        return df[df.index + step <= now].tail(n)

    def intraday_history(self, sym, tf="M5", n=2000):
        return self._hist(sym, "30d", "5m").tail(n)

    def price(self, sym):
        df = self._hist(sym, "1d", "1m")
        return float(df["close"].iloc[-1])

    def digits(self, sym):
        return None


class DemoFeed:
    """Synthetic random-walk prices so the whole pipeline can be tried without
    any broker or internet. Each price() call moves the price one step."""

    def __init__(self, cfg=None, seed=7):
        self.rng = np.random.default_rng(seed)
        self.paths = {}

    def _path(self, sym):
        if sym not in self.paths:
            start = {"GOLD": 2400.0, "BTC": 65000.0}.get(sym.upper(), 100.0)
            n = 400 * 288  # 400 days of 5-minute bars
            drift = self.rng.choice([-1, 1]) * 0.00002
            steps = self.rng.normal(drift * 0.3, 0.0012, n)
            close = start * np.exp(np.cumsum(steps))
            idx = pd.date_range(end=pd.Timestamp.now("UTC").floor("5min"), periods=n, freq="5min")
            noise = np.abs(self.rng.normal(0, 0.0006, n)) * close
            df = pd.DataFrame({"open": np.r_[close[0], close[:-1]], "close": close}, index=idx)
            df["high"] = df[["open", "close"]].max(axis=1) + noise
            df["low"] = df[["open", "close"]].min(axis=1) - noise
            self.paths[sym] = {"m5": df[["open", "high", "low", "close"]], "price": float(close[-1])}
        return self.paths[sym]

    def daily(self, sym, n=40):
        d = self._path(sym)["m5"].resample("1D").agg(AGG).dropna()
        return d.iloc[:-1].tail(n)

    def bars(self, sym, tf, n=300):
        rule = {"H1": "1h", "H4": "4h", "D1": "1D", "M15": "15min", "M5": "5min"}[tf]
        return self._path(sym)["m5"].resample(rule).agg(AGG).dropna().iloc[:-1].tail(n)

    def intraday_history(self, sym, tf="M5", n=2000):
        return self._path(sym)["m5"].tail(n)

    def price(self, sym):
        p = self._path(sym)
        p["price"] *= float(np.exp(self.rng.normal(0, 0.004)))
        return p["price"]

    def digits(self, sym):
        return None


class SupabaseFeed:
    """Prices from the Twsiat database: the MT5 price bridge writes closed M5 bars (prices_m5)
    and live bids (prices_live, bridge v2.1); this reads them through token-protected functions
    (db/020_alerts.sql). Daily bars are UTC days = Exness server days, same as the MT5 charts."""

    def __init__(self, cfg=None):
        sb = (cfg or {}).get("supabase", {}) or {}
        self.url = (os.environ.get("SUPABASE_URL") or sb.get("url", "")).rstrip("/")
        self.key = os.environ.get("SUPABASE_PUBLISHABLE_KEY") or sb.get("publishable_key", "")
        self.token = os.environ.get("ALERTS_TOKEN") or sb.get("alerts_token", "")
        if not (self.url and self.key and self.token):
            raise RuntimeError("Supabase feed needs SUPABASE_URL, SUPABASE_PUBLISHABLE_KEY and ALERTS_TOKEN")
        self.live_max_age = float(sb.get("live_max_age_seconds", 120))
        self.snapshot_every = float((cfg or {}).get("poll_seconds", 10)) * 0.8
        self.session = requests.Session()
        self._symbols, self._symbols_at = {}, 0.0
        self._snap, self._snap_at = None, 0.0
        self._daily = {}          # sym -> (utc_date, DataFrame of all days incl. today)
        self._wanted = set()
        self._down_until, self._down_reason = 0.0, ""

    def _rpc(self, fn, payload):
        # after a failure, fail fast for 30 s instead of waiting on the network once per instrument
        if time.time() < self._down_until:
            raise RuntimeError(f"database not reachable: {self._down_reason}")
        try:
            return self._rpc_once(fn, payload)
        except Exception as e:
            self._down_until, self._down_reason = time.time() + 30, str(e)[:160]
            raise

    def _rpc_once(self, fn, payload):
        r = self.session.post(f"{self.url}/rest/v1/rpc/{fn}", json=payload, timeout=10,
                              headers={"apikey": self.key, "Authorization": f"Bearer {self.key}"})
        if r.status_code != 200:
            raise RuntimeError(f"{fn}: HTTP {r.status_code} {r.text[:200]}")
        return r.json()

    # ---- symbols ----
    def _symbol_list(self):
        if time.time() - self._symbols_at > 3600 or not self._symbols:
            self._symbols = self._rpc("alerts_symbols", {"p_token": self.token}) or {}
            self._symbols_at = time.time()
        return self._symbols

    def has_symbol(self, sym):
        return sym in self._symbol_list()

    def digits(self, sym):
        return self._symbol_list().get(sym)

    # ---- daily bars ----
    def _days(self, sym):
        today = pd.Timestamp.now(tz="UTC").date()
        cached = self._daily.get(sym)
        if cached and cached[0] == today and time.time() - cached[2] < 6 * 3600:
            return cached[1]
        rows = self._rpc("alerts_daily", {"p_token": self.token, "p_symbol": sym, "p_days": 420})
        if not rows:
            raise RuntimeError(f"No daily data for {sym}")
        df = pd.DataFrame(rows, columns=["day", "open", "high", "low", "close"])
        df.index = pd.to_datetime(df.pop("day"))
        df = df.astype(float)
        self._daily[sym] = (today, df, time.time())
        return df

    def daily(self, sym, n=40):
        df = self._days(sym)
        today = pd.Timestamp.now(tz="UTC").normalize().tz_localize(None)
        return df[df.index < today].tail(n)            # completed days only

    def bars(self, sym, tf, n=300):
        if tf != "D1":
            raise RuntimeError("Supabase feed provides daily bars for the trend (set trend_timeframe: D1)")
        return self.daily(sym, n)

    # ---- live price ----
    def _snapshot(self):
        if self._snap is None or time.time() - self._snap_at > self.snapshot_every:
            syms = sorted(self._wanted or self._symbol_list().keys())
            self._snap = self._rpc("alerts_feed", {"p_token": self.token, "p_symbols": syms})
            self._snap_at = time.time()
        return self._snap

    def price(self, sym):
        self._wanted.add(sym)
        snap = self._snapshot()
        if sym not in (snap.get("live") or {}) and sym not in (snap.get("m5") or {}):
            self._snap = None                              # new symbol: refetch including it
            snap = self._snapshot()
        now = pd.Timestamp(snap["now"])
        live, m5 = (snap.get("live") or {}).get(sym), (snap.get("m5") or {}).get(sym)
        best = None
        if live:
            t = pd.Timestamp(live[1])
            if (now - t).total_seconds() <= self.live_max_age:
                best = (float(live[0]), t)
        if best is None:                                   # no fresh live quote: newest of what we have
            cands = [(float(v[0]), pd.Timestamp(v[1])) for v in (live, m5) if v]
            if cands:
                best = max(cands, key=lambda x: x[1])
        if best is None:
            raise RuntimeError(f"No price for {sym}")
        self._quote_time = getattr(self, "_quote_time", {})
        self._quote_time[sym] = best[1].isoformat()
        return best[0]

    def quote_time(self, sym):
        return getattr(self, "_quote_time", {}).get(sym)


def make_feed(name, cfg=None):
    return {"mt5": MT5Feed, "yahoo": YahooFeed, "demo": DemoFeed, "supabase": SupabaseFeed}[name](cfg)
