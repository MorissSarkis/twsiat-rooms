'use client';
import { useEffect, useState } from 'react';
// Shown to signed-in members until they link Telegram.
// "لاحقاً" hides it for 7 days; pressing the button hides it for 3 days (in case they didn't finish in Telegram).
const KEY = 'tgPromptHiddenUntil';
const hideFor = (days) => { try { localStorage.setItem(KEY, String(Date.now() + days * 864e5)); } catch {} };

export default function TelegramPrompt({ link }) {
  const [hidden, setHidden] = useState(true);   // hidden until we know it wasn't dismissed (no flash)
  useEffect(() => {
    let until = 0;
    try { until = Number(localStorage.getItem(KEY)) || 0; } catch {}
    setHidden(until > Date.now());
  }, []);
  if (!link || hidden) return null;
  return (
    <div className="card row tgp" style={{ justifyContent: 'space-between' }}>
      <div style={{ flex: '1 1 220px' }}>
        <b>فعّل إشعارات تيليجرام 🔔</b>
        <div className="muted" style={{ marginTop: 4, lineHeight: 1.7 }}>توصلك توصيات غرفتك وتحديثاتها على الخاص أول بأول. اضغط الزر وبعدين <b>Start</b> بالبوت.</div>
      </div>
      <div className="row">
        <button type="button" className="btn ghost" onClick={() => { hideFor(7); setHidden(true); }}>لاحقاً</button>
        <a className="btn" href={link} target="_blank" rel="noopener" onClick={() => { hideFor(3); setTimeout(() => setHidden(true), 300); }}>فعّل الإشعارات</a>
      </div>
    </div>
  );
}
