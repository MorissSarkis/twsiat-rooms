"""Telegram sender. With no bot token configured it prints to the console instead."""
import logging
import time

import requests

log = logging.getLogger("notifier")


class Telegram:
    def __init__(self, token: str = "", chat_ids=None):
        self.token = (token or "").strip()
        self.chat_ids = [str(c) for c in (chat_ids or [])]
        self.dry_run = not (self.token and self.chat_ids)
        self.offset = None
        if self.dry_run:
            log.warning("Telegram not configured — alerts will be printed only.")

    def get_updates(self):
        """New command messages, only from the configured chats (anyone else is ignored)."""
        if self.dry_run:
            return []
        try:
            params = {"timeout": 0, "allowed_updates": '["message"]'}
            if self.offset is not None:
                params["offset"] = self.offset
            r = requests.get(f"https://api.telegram.org/bot{self.token}/getUpdates", params=params, timeout=15)
            r.raise_for_status()
            out = []
            for u in r.json().get("result", []):
                self.offset = u["update_id"] + 1
                m = u.get("message") or {}
                chat, text = str(m.get("chat", {}).get("id", "")), m.get("text", "")
                if chat in self.chat_ids and text.startswith("/"):
                    out.append((chat, text))
            return out
        except Exception as e:
            log.error("Telegram getUpdates failed: %s", e)
            return []

    def send(self, text: str, chat_id=None):
        if self.dry_run:
            print("\n" + text.replace("<b>", "").replace("</b>", "") + "\n" + "-" * 40)
            return
        for chunk in _chunks(text, 3900):
            for chat in ([str(chat_id)] if chat_id else self.chat_ids):
                for attempt in range(3):
                    try:
                        r = requests.post(
                            f"https://api.telegram.org/bot{self.token}/sendMessage",
                            json={"chat_id": chat, "text": chunk, "parse_mode": "HTML",
                                  "disable_web_page_preview": True},
                            timeout=15,
                        )
                        if r.status_code == 429:  # rate limited
                            time.sleep(r.json().get("parameters", {}).get("retry_after", 3))
                            continue
                        r.raise_for_status()
                        break
                    except Exception as e:
                        log.error("Telegram send to %s failed (%s), attempt %d", chat, e, attempt + 1)
                        time.sleep(2)


def _chunks(text, size):
    lines, buf = text.split("\n"), ""
    for line in lines:
        if len(buf) + len(line) + 1 > size:
            yield buf
            buf = ""
        buf += line + "\n"
    if buf.strip():
        yield buf


class WhatsApp:
    """Official WhatsApp Cloud API (Meta). Sends each alert to every number in `to`.

    WhatsApp rules: a business may send free-form text only within 24h after the
    person last messaged the number. Outside that window it must use an approved
    template. So: try plain text first; if WhatsApp refuses because the window is
    closed (error 131047), resend through the template, with the alert as its one
    variable (templates don't allow line breaks, so lines are joined with ' | ')."""

    API = "https://graph.facebook.com/v21.0/{pid}/messages"

    def __init__(self, phone_number_id="", access_token="", to=None,
                 template_name="pivot_alert", template_lang="en"):
        self.pid = str(phone_number_id or "").strip()
        self.token = (access_token or "").strip()
        self.to = [str(n).replace("+", "").replace(" ", "") for n in (to or [])]
        self.template, self.lang = template_name, template_lang
        self.dry_run = not (self.pid and self.token and self.to)
        if self.dry_run:
            log.warning("WhatsApp not configured — alerts will be printed only.")

    def get_updates(self):
        return []   # incoming commands need a public webhook; use Telegram for commands

    def _post(self, payload):
        return requests.post(self.API.format(pid=self.pid), json=payload, timeout=15,
                             headers={"Authorization": f"Bearer {self.token}"})

    def send(self, text: str, chat_id=None):
        plain = text.replace("<b>", "*").replace("</b>", "*")      # WhatsApp bold = *text*
        if self.dry_run:
            print("\n" + plain + "\n" + "-" * 40)
            return
        for chunk in _chunks(plain, 3500):
            for num in ([str(chat_id)] if chat_id else self.to):
                try:
                    r = self._post({"messaging_product": "whatsapp", "to": num, "type": "text",
                                    "text": {"body": chunk, "preview_url": False}})
                    code = (r.json().get("error") or {}).get("code") if r.status_code >= 400 else None
                    if code == 131047:   # 24h window closed -> approved template
                        one_line = " | ".join(x.strip() for x in chunk.splitlines() if x.strip())[:1000]
                        r = self._post({"messaging_product": "whatsapp", "to": num, "type": "template",
                                        "template": {"name": self.template, "language": {"code": self.lang},
                                                     "components": [{"type": "body", "parameters": [
                                                         {"type": "text", "text": one_line}]}]}})
                    if r.status_code >= 400:
                        log.error("WhatsApp send to %s failed: %s", num, r.text[:300])
                except Exception as e:
                    log.error("WhatsApp send to %s failed: %s", num, e)


def make_notifier(cfg):
    if cfg.get("channel", "whatsapp") == "whatsapp":
        w = cfg.get("whatsapp", {}) or {}
        return WhatsApp(w.get("phone_number_id"), w.get("access_token"), w.get("to"),
                        w.get("template_name", "pivot_alert"), w.get("template_lang", "en"))
    tg = cfg.get("telegram", {}) or {}
    return Telegram(tg.get("bot_token", ""), tg.get("chat_ids", []))
