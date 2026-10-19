'use client';
import { useState } from 'react';
// Shown to signed-in members until they link Telegram. Disappears once pressed.
export default function TelegramPrompt({ link }) {
  const [hidden, setHidden] = useState(false);
  if (!link || hidden) return null;
  return (
    <div className="card row tgp" style={{ justifyContent: 'space-between' }}>
      <div style={{ flex: '1 1 220px' }}>
        <b>فعّل إشعارات تيليجرام 🔔</b>
        <div className="muted" style={{ marginTop: 4, lineHeight: 1.7 }}>توصلك توصيات غرفتك وتحديثاتها على الخاص أول بأول. اضغط الزر وبعدين <b>Start</b> بالبوت.</div>
      </div>
      <a className="btn" href={link} target="_blank" rel="noopener" onClick={() => setTimeout(() => setHidden(true), 300)}>فعّل الإشعارات</a>
    </div>
  );
}
