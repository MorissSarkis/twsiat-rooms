"""Private web app + phone notifications for the pivot alerts.

    python main.py            # starts the alert engine and the app (see README)
"""
import hmac
import json
import logging
import os
import secrets
import threading
import time
from concurrent.futures import ThreadPoolExecutor

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse

import webpush

log = logging.getLogger("server")
HERE = os.path.dirname(os.path.abspath(__file__))
WEB = os.path.join(HERE, "web")
COOKIE = "pa_session"
SESSION_DAYS = 90


class PushHub:
    """Phone/browser subscriptions + sending. Subscriptions live in subscriptions.json."""

    def __init__(self, data_dir, subject):
        self.path = os.path.join(data_dir, "subscriptions.json")
        self.vapid = webpush.Vapid(os.path.join(data_dir, "vapid.json"), subject)
        self.lock = threading.Lock()
        self.pool = ThreadPoolExecutor(max_workers=4)
        try:
            with open(self.path) as f:
                self.subs = json.load(f)
        except Exception:
            self.subs = []

    def _save(self):
        with open(self.path, "w") as f:
            json.dump(self.subs, f)

    def add(self, sub, label=""):
        with self.lock:
            self.subs = [s for s in self.subs if s["endpoint"] != sub["endpoint"]]
            self.subs.append({"endpoint": sub["endpoint"], "keys": sub["keys"], "label": label,
                              "added": int(time.time())})
            self._save()

    def remove(self, endpoint):
        with self.lock:
            self.subs = [s for s in self.subs if s["endpoint"] != endpoint]
            self._save()

    def deliver(self, item):
        data = {"title": item["title"], "body": item["body"], "tag": f"{item['asset']}-{item.get('level')}",
                "action": item.get("action"), "id": item["id"], "url": "/#alerts"}
        urgency = "high" if item.get("action") in ("down", "up", "break") else "normal"
        for s in list(self.subs):
            self.pool.submit(self._send_one, s, data, urgency)

    def _send_one(self, sub, data, urgency):
        try:
            code = webpush.send(sub, data, self.vapid, ttl=3600, urgency=urgency)
            if code in (404, 410):
                log.info("push subscription expired, removing")
                self.remove(sub["endpoint"])
            elif code >= 400:
                log.error("push failed with HTTP %s", code)
        except Exception as e:
            log.error("push failed: %s", e)


class Sessions:
    def __init__(self, data_dir):
        self.path = os.path.join(data_dir, "sessions.json")
        try:
            with open(self.path) as f:
                self.tokens = json.load(f)
        except Exception:
            self.tokens = {}
        self.fails = {}

    def _save(self):
        with open(self.path, "w") as f:
            json.dump(self.tokens, f)

    def create(self):
        t = secrets.token_urlsafe(32)
        self.tokens[t] = time.time() + SESSION_DAYS * 86400
        self._save()
        return t

    def valid(self, t):
        exp = self.tokens.get(t or "")
        return bool(exp and exp > time.time())

    def drop(self, t):
        if self.tokens.pop(t or "", None):
            self._save()

    def too_many_fails(self, ip):
        now = time.time()
        self.fails[ip] = [x for x in self.fails.get(ip, []) if now - x < 900]
        return len(self.fails[ip]) >= 10

    def fail(self, ip):
        self.fails.setdefault(ip, []).append(time.time())


def create_app(service, hub: PushHub, password: str, data_dir: str):
    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    sessions = Sessions(data_dir)

    def authed(req: Request):
        return sessions.valid(req.cookies.get(COOKIE))

    def need_auth(req: Request):
        if not authed(req):
            raise HTTPException(401, "login required")

    def secure(req: Request):
        return req.headers.get("x-forwarded-proto", req.url.scheme) == "https"

    # ---------- pages ----------
    @app.get("/")
    def index(req: Request):
        if not authed(req):
            return RedirectResponse("/login", 302)
        return FileResponse(os.path.join(WEB, "index.html"), headers={"Cache-Control": "no-cache"})

    @app.get("/login")
    def login_page():
        return FileResponse(os.path.join(WEB, "login.html"), headers={"Cache-Control": "no-cache"})

    @app.get("/sw.js")
    def sw():
        return FileResponse(os.path.join(WEB, "sw.js"), media_type="text/javascript",
                            headers={"Cache-Control": "no-cache", "Service-Worker-Allowed": "/"})

    @app.get("/manifest.webmanifest")
    def manifest():
        return FileResponse(os.path.join(WEB, "manifest.webmanifest"), media_type="application/manifest+json")

    @app.get("/{name}.png")
    def icon(name: str):
        p = os.path.join(WEB, f"{name}.png")
        if name not in ("icon-192", "icon-512", "apple-touch-icon", "badge") or not os.path.exists(p):
            raise HTTPException(404)
        return FileResponse(p, media_type="image/png")

    # ---------- auth ----------
    @app.post("/api/login")
    async def login(req: Request):
        ip = req.client.host if req.client else "?"
        if sessions.too_many_fails(ip):
            raise HTTPException(429, "محاولات كثيرة، جرّب بعد ربع ساعة")
        body = await req.json()
        if not password or not hmac.compare_digest(str(body.get("password", "")).encode(), password.encode()):
            sessions.fail(ip)
            raise HTTPException(401, "كلمة السر غير صحيحة")
        resp = JSONResponse({"ok": True})
        resp.set_cookie(COOKIE, sessions.create(), max_age=SESSION_DAYS * 86400, httponly=True,
                        samesite="lax", secure=secure(req))
        return resp

    @app.post("/api/logout")
    def logout(req: Request):
        sessions.drop(req.cookies.get(COOKIE))
        resp = JSONResponse({"ok": True})
        resp.delete_cookie(COOKIE)
        return resp

    # ---------- data ----------
    @app.get("/api/state")
    def state(req: Request):
        need_auth(req)
        snap = service.snapshot()
        snap["push_devices"] = len(hub.subs)
        return snap

    @app.get("/api/alerts")
    def alerts(req: Request, limit: int = 200):
        need_auth(req)
        return {"alerts": service.history(min(limit, 500))}

    @app.get("/api/vapid")
    def vapid(req: Request):
        need_auth(req)
        return {"key": hub.vapid.public_b64}

    @app.post("/api/subscribe")
    async def subscribe(req: Request):
        need_auth(req)
        body = await req.json()
        sub = body.get("subscription") or {}
        if not sub.get("endpoint", "").startswith("https://") or "p256dh" not in sub.get("keys", {}):
            raise HTTPException(400, "bad subscription")
        hub.add(sub, (req.headers.get("user-agent") or "")[:120])
        return {"ok": True, "devices": len(hub.subs)}

    @app.post("/api/unsubscribe")
    async def unsubscribe(req: Request):
        need_auth(req)
        body = await req.json()
        hub.remove(body.get("endpoint", ""))
        return {"ok": True}

    @app.post("/api/test")
    def test(req: Request):
        need_auth(req)
        item = service._emit("TEST", "🔔 تنبيه تجريبي", "إذا وصلك هذا الإشعار، كل شي شغال تمام.", "info", "test")
        return {"ok": True, "devices": len(hub.subs), "id": item["id"]}

    @app.post("/api/settings")
    async def settings(req: Request):
        need_auth(req)
        b = await req.json()
        service.update_settings(b.get("muted"), b.get("levels"), b.get("approach"))
        return {"ok": True, "settings": service.state["settings"]}

    @app.post("/api/override")
    async def override(req: Request):
        need_auth(req)
        b = await req.json()
        if b.get("trend") not in ("up", "down"):
            raise HTTPException(400, "trend must be up or down")
        try:
            service.set_override(b["asset"], b["trend"], float(b["anchor"]))
        except ValueError as e:
            raise HTTPException(400, str(e))
        return {"ok": True}

    @app.post("/api/override/clear")
    async def clear_override(req: Request):
        need_auth(req)
        b = await req.json()
        service.clear_override(b.get("asset", ""))
        return {"ok": True}

    return app
