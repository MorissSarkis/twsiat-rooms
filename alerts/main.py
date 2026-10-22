"""Pivot Alerts — starts the alert engine and the private app.

    python main.py               # real prices from MT5 (config.yaml)
    python main.py --feed demo   # simulated prices, to try the app without MT5

Then open http://localhost:8080 (or your domain) and log in with the password in config.yaml.
"""
import argparse
import logging
import os
import sys
import threading

import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from access import Directory  # noqa: E402
from feeds import make_feed  # noqa: E402
from notifier import Telegram, WhatsApp  # noqa: E402
from server import PushHub, create_app  # noqa: E402
from service import AlertService  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
log = logging.getLogger("pivot_alerts")


class TextSink:
    """Optional extra channel (Telegram / WhatsApp) next to the app notifications."""

    def __init__(self, notifier):
        self.n = notifier

    def deliver(self, item):
        self.n.send(f"<b>{item['title']}</b>\n{item['body']}")


def build(cfg, data_dir):
    os.makedirs(data_dir, exist_ok=True)
    app_cfg = cfg.get("app", {}) or {}
    hub = PushHub(data_dir, app_cfg.get("contact", "mailto:alerts@example.com"))
    sinks = [hub]
    extra = cfg.get("extra_channels", []) or []
    if "telegram" in extra:
        tg = cfg.get("telegram", {}) or {}
        sinks.append(TextSink(Telegram(tg.get("bot_token", ""), tg.get("chat_ids", []))))
    if "whatsapp" in extra:
        w = cfg.get("whatsapp", {}) or {}
        sinks.append(TextSink(WhatsApp(w.get("phone_number_id"), w.get("access_token"), w.get("to"),
                                       w.get("template_name", "pivot_alert"), w.get("template_lang", "en"))))
    service = AlertService(cfg, make_feed(cfg.get("feed", "mt5"), cfg), data_dir, sinks)
    # members of rooms.twsiat.com sign in with their own account (only with the Supabase feed / settings)
    directory = Directory(data_dir) if cfg.get("feed") == "supabase" else None
    app = create_app(service, hub, str(app_cfg.get("password", "")), data_dir, directory,
                     os.environ.get("ROOMS_URL") or app_cfg.get("rooms_url", "https://rooms.twsiat.com"))
    app.state.directory = directory
    return service, hub, app


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=os.path.join(HERE, "config.yaml"))
    ap.add_argument("--feed", choices=["mt5", "yahoo", "demo"])
    ap.add_argument("--port", type=int)
    args = ap.parse_args()
    data_dir = os.environ.get("ALERTS_DATA") or os.path.join(HERE, "data")
    os.makedirs(data_dir, exist_ok=True)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s",
                        handlers=[logging.StreamHandler(),
                                  logging.FileHandler(os.path.join(data_dir, "alerts.log"), encoding="utf-8")])
    with open(args.config, encoding="utf-8") as f:
        cfg = yaml.safe_load(f)
    if args.feed:
        cfg["feed"] = args.feed
    # secrets come from the environment on the server (deploy/.env), never from the repo
    app_env = cfg.setdefault("app", {})
    if os.environ.get("ALERTS_PASSWORD"):
        app_env["password"] = os.environ["ALERTS_PASSWORD"]
    if os.environ.get("ALERTS_CONTACT"):
        app_env["contact"] = os.environ["ALERTS_CONTACT"]
    if cfg["feed"] == "demo":
        cfg["poll_seconds"] = 3
    app_cfg = cfg.get("app", {}) or {}
    if not str(app_cfg.get("password", "")).strip() or app_cfg.get("password") == "CHANGE-ME":
        sys.exit("Set app.password in config.yaml first.")

    service, hub, app = build(cfg, data_dir)
    threading.Thread(target=service.run_forever, daemon=True, name="engine").start()
    directory = app.state.directory
    if directory and directory.enabled:   # re-check members' access every 10 minutes
        sessions = app.state.sessions
        threading.Thread(target=directory.run_forever, args=(lambda: sessions.uids() | hub.uids(),),
                         daemon=True, name="access").start()

    import uvicorn
    uvicorn.run(app, host=app_cfg.get("host", "0.0.0.0"), port=args.port or app_cfg.get("port", 8080),
                proxy_headers=True, forwarded_allow_ips="*", log_level="warning")


if __name__ == "__main__":
    main()
