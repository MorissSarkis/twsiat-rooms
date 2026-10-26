"""Who may use the app: members of rooms.twsiat.com with alerts access (db/021_alerts_access.sql).

    free  : IB clients (verified under the Twsiat tag)
    paid  : crypto subscription, approved by staff
    staff : analyst / manager / admin

The members site issues a one-time code, we redeem it here with ALERTS_TOKEN. Access is re-checked
every few minutes, so an expired subscription stops notifications without anyone logging out.
"owner" is the password login (the old shared login), always allowed and admin.
"""
import json
import logging
import os
import threading
import time

import requests

log = logging.getLogger("access")
OWNER = "owner"
ADMIN_ROLES = ("manager", "admin")


class Directory:
    def __init__(self, data_dir, url=None, key=None, token=None, ttl=600):
        self.url = (url or os.environ.get("SUPABASE_URL", "")).rstrip("/")
        self.key = key or os.environ.get("SUPABASE_PUBLISHABLE_KEY", "")
        self.token = token or os.environ.get("ALERTS_TOKEN", "")
        self.ttl = ttl
        self.path = os.path.join(data_dir, "access.json")
        self.lock = threading.Lock()
        self.http = requests.Session()
        try:
            with open(self.path) as f:
                self.cache = json.load(f)          # uid -> {ok, reason, role, until, at, name}
        except Exception:
            self.cache = {}

    @property
    def enabled(self):
        return bool(self.url and self.key and self.token)

    def _rpc(self, fn, payload):
        r = self.http.post(f"{self.url}/rest/v1/rpc/{fn}", json=payload, timeout=10,
                           headers={"apikey": self.key, "Authorization": f"Bearer {self.key}"})
        if r.status_code != 200:
            raise RuntimeError(f"{fn}: HTTP {r.status_code} {r.text[:200]}")
        return r.json()

    def _save(self):
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.cache, f)
        os.replace(tmp, self.path)

    def _store(self, uid, acc, name=None):
        with self.lock:
            old = self.cache.get(uid, {})
            self.cache[uid] = {**(acc or {"ok": False}), "at": time.time(),
                               "name": name if name is not None else old.get("name", "")}
            self._save()

    # ---------- login hand-off ----------
    def redeem(self, code):
        """one-time code -> {"user_id", "name", "access"} or None when unknown/expired/used"""
        if not code or len(code) > 128 or not code.isalnum():
            return None
        info = self._rpc("alerts_redeem_code", {"p_token": self.token, "p_code": code})
        if info:
            self._store(info["user_id"], info.get("access"), info.get("name") or "")
        return info

    # ---------- checks ----------
    def refresh(self, uids):
        uids = sorted({u for u in uids if u and u != OWNER})
        for i in range(0, len(uids), 200):
            part = uids[i:i + 200]
            res = self._rpc("alerts_check_users", {"p_token": self.token, "p_ids": part}) or {}
            for u in part:
                self._store(u, res.get(u))

    def info(self, uid):
        if uid == OWNER:
            return {"ok": True, "reason": "owner", "role": "admin", "name": "الإدارة"}
        e = self.cache.get(uid)
        if e is None and self.enabled:
            try:                       # first time we see this person since the cache was made
                self.refresh([uid])
                e = self.cache.get(uid)
            except Exception as ex:
                log.warning("access check failed for %s: %s", uid, ex)
        return e or {"ok": False, "reason": "none"}

    def ok(self, uid):
        e = self.info(uid)
        if not e.get("ok"):
            return False
        until = e.get("until")
        if e.get("reason") in ("paid", "trial") and until:   # stop at the end date without waiting for the next check
            try:
                from datetime import datetime
                return datetime.fromisoformat(until.replace("Z", "+00:00")).timestamp() > time.time()
            except Exception:
                return True
        return True

    def is_admin(self, uid):
        return uid == OWNER or self.info(uid).get("role") in ADMIN_ROLES

    def run_forever(self, uids_fn, stop_event=None):
        while not (stop_event and stop_event.is_set()):
            time.sleep(self.ttl)
            try:
                self.refresh(uids_fn())
            except Exception as ex:      # keep the last known answer; prices are probably down too
                log.warning("access refresh failed: %s", ex)
