"""Private web app + phone notifications for the pivot alerts.

    python main.py            # starts the alert engine and the app (see README)

Sign-in: members come from rooms.twsiat.com/alerts with a one-time code (/auth?code=...), see access.py.
The shared password stays as the owner's login.
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
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, RedirectResponse

import messages_en as EN
import webpush
from access import OWNER

log = logging.getLogger("server")
HERE = os.path.dirname(os.path.abspath(__file__))
WEB = os.path.join(HERE, "web")
COOKIE = "pa_session"
SESSION_DAYS = 90


class PushHub:
    """Phone/browser subscriptions + sending. Subscriptions live in subscriptions.json.
    Each phone belongs to one person (uid); allow(uid, item) decides if it rings."""
    per_user = True

    def __init__(self, data_dir, subject):
        self.allow = lambda uid, item: True
        self.localize = lambda uid, item: item          # each phone gets the alert in its owner's language
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

    def add(self, sub, label="", uid=OWNER):
        with self.lock:      # same phone, new person -> it now belongs to the new person
            self.subs = [s for s in self.subs if s["endpoint"] != sub["endpoint"]]
            self.subs.append({"endpoint": sub["endpoint"], "keys": sub["keys"], "label": label,
                              "uid": uid, "added": int(time.time())})
            self._save()

    def count(self, uid):
        return sum(1 for s in self.subs if s.get("uid", OWNER) == uid)

    def uids(self):
        return {s.get("uid", OWNER) for s in self.subs}

    def remove(self, endpoint):
        with self.lock:
            self.subs = [s for s in self.subs if s["endpoint"] != endpoint]
            self._save()

    def deliver(self, item):
        urgency = "high" if item.get("action") in ("down", "up", "break") else "normal"
        for s in list(self.subs):
            uid = s.get("uid", OWNER)
            try:
                if not self.allow(uid, item):
                    continue
                it = self.localize(uid, item)
            except Exception as e:
                log.error("allow check failed: %s", e)
                continue
            data = {"title": it["title"], "body": it["body"], "tag": f"{it['asset']}-{it.get('level')}",
                    "action": it.get("action"), "id": it["id"], "url": "/#alerts"}
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
    """cookie token -> {"exp", "uid"}. Old sessions (just an expiry) were the shared password = owner."""

    def __init__(self, data_dir):
        self.path = os.path.join(data_dir, "sessions.json")
        self.lock = threading.Lock()
        try:
            with open(self.path) as f:
                raw = json.load(f)
        except Exception:
            raw = {}
        self.tokens = {t: (v if isinstance(v, dict) else {"exp": v, "uid": OWNER}) for t, v in raw.items()}
        self.fails = {}

    def _save(self):
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.tokens, f)
        os.replace(tmp, self.path)

    def create(self, uid=OWNER):
        t = secrets.token_urlsafe(32)
        now = time.time()
        with self.lock:
            self.tokens = {k: v for k, v in self.tokens.items() if v["exp"] > now}
            self.tokens[t] = {"exp": now + SESSION_DAYS * 86400, "uid": uid}
            self._save()
        return t

    def uid(self, t):
        e = self.tokens.get(t or "")
        return e["uid"] if e and e["exp"] > time.time() else None

    def valid(self, t):
        return self.uid(t) is not None

    def uids(self):
        now = time.time()
        return {v["uid"] for v in self.tokens.values() if v["exp"] > now}

    def drop(self, t):
        with self.lock:
            if self.tokens.pop(t or "", None):
                self._save()

    def too_many_fails(self, ip):
        now = time.time()
        self.fails[ip] = [x for x in self.fails.get(ip, []) if now - x < 900]
        return len(self.fails[ip]) >= 10

    def fail(self, ip):
        self.fails.setdefault(ip, []).append(time.time())


PAGE = """<!doctype html><html lang="ar" dir="rtl"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover"><meta name="theme-color" content="#0e141b">
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans+Arabic:wght@400;600;700&display=swap" rel="stylesheet">
<title>تنبيهات البيفوت</title><style>
body{margin:0;min-height:100vh;display:grid;place-items:center;background:#0e141b;color:#e6edf5;padding:24px 16px;
font-family:"IBM Plex Sans Arabic",-apple-system,"Segoe UI",Tahoma,sans-serif;text-align:center}
.box{max-width:380px}img{width:64px;height:64px;border-radius:16px}h1{font-size:21px;margin:16px 0 8px}
p{color:#8a9bb0;line-height:1.8;font-size:14px;margin:0 0 22px}
a.b{display:block;padding:14px;border-radius:12px;background:#f5b53f;color:#1a1205;font-weight:600;text-decoration:none}
a.g{display:block;margin-top:12px;color:#8a9bb0;font-size:14px}</style></head>
<body><div class="box"><img src="/icon-192.png" alt=""><h1>{title}</h1><p>{text}</p>
<a class="b" href="{href}">{button}</a>{extra}</div></body></html>"""


def page(title, text, href, button, extra="", status=200):
    html = PAGE
    for k, v in (("{title}", title), ("{text}", text), ("{href}", href), ("{button}", button), ("{extra}", extra)):
        html = html.replace(k, v)
    return HTMLResponse(html, status_code=status,
                        headers={"Cache-Control": "no-store", "Referrer-Policy": "no-referrer"})


def create_app(service, hub: PushHub, password: str, data_dir: str, directory=None,
               rooms_url="https://rooms.twsiat.com"):
    app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)
    sessions = Sessions(data_dir)
    members = f"{rooms_url.rstrip('/')}/alerts"

    def access_ok(uid):
        return uid == OWNER or bool(directory and directory.ok(uid))

    def is_admin(uid):
        return uid == OWNER or bool(directory and directory.is_admin(uid))

    # a phone rings only while its owner has access, and only for what they chose
    hub.allow = lambda uid, item: access_ok(uid) and service.wants(uid, item)
    hub.localize = lambda uid, item: service.localize(item, service.lang(uid))

    def who(req: Request):
        return sessions.uid(req.cookies.get(COOKIE))

    def need_auth(req: Request):
        uid = who(req)
        if not uid:
            raise HTTPException(401, "login required")
        if not access_ok(uid):
            raise HTTPException(403, "expired")
        return uid

    def need_admin(req: Request):
        uid = need_auth(req)
        if not is_admin(uid):
            raise HTTPException(403, "للإدارة بس")
        return uid

    def secure(req: Request):
        return req.headers.get("x-forwarded-proto", req.url.scheme) == "https"

    def signed_in(req: Request, uid, to="/"):
        resp = RedirectResponse(to, 302) if to else JSONResponse({"ok": True})
        resp.set_cookie(COOKIE, sessions.create(uid), max_age=SESSION_DAYS * 86400, httponly=True,
                        samesite="lax", secure=secure(req))
        return resp

    # ---------- pages ----------
    @app.get("/")
    def index(req: Request):
        uid = who(req)
        if not uid:
            return RedirectResponse("/login", 302)
        if not access_ok(uid):
            return RedirectResponse("/expired", 302)
        return FileResponse(os.path.join(WEB, "index.html"), headers={"Cache-Control": "no-cache"})

    @app.get("/login")
    def login_page():
        return FileResponse(os.path.join(WEB, "login.html"), headers={"Cache-Control": "no-cache"})

    @app.get("/config.json")
    def public_config():
        return {"members": members, "member_login": bool(directory and directory.enabled)}

    @app.get("/expired")
    def expired():
        return page("اشتراكك بالتنبيهات غير فعّال",
                    "التنبيهات مجانية لعملاء وكالة موقع توصيات، أو باشتراك شهري. "
                    "فعّل أو جدّد من صفحة التنبيهات بموقع الأعضاء، ورجع افتح التطبيق.",
                    members, "فعّل أو جدّد الاشتراك · Activate or renew",
                    '<p dir="ltr" style="margin:22px 0 0">Your alerts subscription is not active. Alerts are free for Twsiat '
                    'agency clients, or available with a monthly subscription. Activate or renew on the members site, '
                    'then open the app again.</p>'
                    '<a class="g" href="/login">دخول بحساب ثاني · Sign in with another account</a>')

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
        if name not in ("icon-192", "icon-512", "icon-maskable-512", "apple-touch-icon", "badge") or not os.path.exists(p):
            raise HTTPException(404)
        return FileResponse(p, media_type="image/png")

    # ---------- auth ----------
    @app.get("/auth")
    def auth(req: Request, code: str = ""):
        """members site -> one-time code -> signed in here"""
        ip = req.client.host if req.client else "?"
        if not (directory and directory.enabled):
            return RedirectResponse("/login", 302)
        if sessions.too_many_fails(ip):
            return page("محاولات كثيرة", "جرّب بعد ربع ساعة.", members, "رجوع", status=429)
        try:
            info = directory.redeem(code)
        except Exception as e:
            log.error("code redeem failed: %s", e)
            return page("ما قدرنا نكمّل الدخول", "صار خطأ بالاتصال. جرّب مرة ثانية بعد شوي.", members, "حاول مرة ثانية",
                        status=503)
        if not info:
            sessions.fail(ip)
            return page("الرابط انتهى", "رابط الدخول بيشتغل مرة وحدة ولمدة دقيقتين. ارجع لصفحة التنبيهات واضغط «افتح» مرة ثانية.",
                        members, "رجوع لصفحة التنبيهات", status=400)
        uid = info["user_id"]
        if not (info.get("access") or {}).get("ok"):
            return RedirectResponse("/expired", 302)
        log.info("member signed in: %s", uid)
        return signed_in(req, uid)

    @app.post("/api/login")
    async def login(req: Request):
        ip = req.client.host if req.client else "?"
        if sessions.too_many_fails(ip):
            raise HTTPException(429, "محاولات كثيرة، جرّب بعد ربع ساعة")
        body = await req.json()
        if not password or not hmac.compare_digest(str(body.get("password", "")).encode(), password.encode()):
            sessions.fail(ip)
            raise HTTPException(401, "كلمة السر غير صحيحة")
        return signed_in(req, OWNER, to=None)

    @app.post("/api/logout")
    def logout(req: Request):
        sessions.drop(req.cookies.get(COOKIE))
        resp = JSONResponse({"ok": True})
        resp.delete_cookie(COOKIE)
        return resp

    # ---------- data ----------
    @app.get("/api/state")
    def state(req: Request):
        uid = need_auth(req)
        snap = service.snapshot(uid)
        snap["push_devices"] = hub.count(uid)
        info = directory.info(uid) if (directory and uid != OWNER) else {"reason": "owner"}
        snap["me"] = {"name": info.get("name") or "", "reason": info.get("reason"), "until": info.get("until"),
                      "admin": is_admin(uid), "members": members}
        if is_admin(uid):
            snap["me"]["stats"] = {"people": len(hub.uids()), "devices": len(hub.subs)}
        return snap

    @app.get("/api/alerts")
    def alerts(req: Request, limit: int = 200):
        uid = need_auth(req)
        return {"alerts": service.history(min(limit, 500), uid)}

    @app.get("/api/vapid")
    def vapid(req: Request):
        need_auth(req)
        return {"key": hub.vapid.public_b64}

    @app.post("/api/subscribe")
    async def subscribe(req: Request):
        uid = need_auth(req)
        body = await req.json()
        sub = body.get("subscription") or {}
        if not sub.get("endpoint", "").startswith("https://") or "p256dh" not in sub.get("keys", {}):
            raise HTTPException(400, "bad subscription")
        hub.add(sub, (req.headers.get("user-agent") or "")[:120], uid)
        return {"ok": True, "devices": hub.count(uid)}

    @app.post("/api/unsubscribe")
    async def unsubscribe(req: Request):
        need_auth(req)
        body = await req.json()
        hub.remove(body.get("endpoint", ""))
        return {"ok": True}

    @app.post("/api/test")
    def test(req: Request):
        uid = need_auth(req)
        item = service._emit("TEST", "🔔 تنبيه تجريبي", "إذا وصلك هذا الإشعار، كل شي شغال تمام.", "info", "test",
                             extra={"to": uid, "en": {"title": EN.TEST_TITLE, "body": EN.TEST_BODY}})
        return {"ok": True, "devices": hub.count(uid), "id": item["id"]}

    @app.post("/api/settings")
    async def settings(req: Request):
        uid = need_auth(req)
        b = await req.json()
        service.update_settings(b.get("muted"), b.get("levels"), b.get("approach"), uid=uid, lang=b.get("lang"))
        return {"ok": True, "settings": service.user_settings(uid)}

    # manual bottom/top: one for everyone, so the team sets it
    @app.post("/api/override")
    async def override(req: Request):
        need_admin(req)
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
        need_admin(req)
        b = await req.json()
        service.clear_override(b.get("asset", ""))
        return {"ok": True}

    app.state.sessions = sessions
    return app
