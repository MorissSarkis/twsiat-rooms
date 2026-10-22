'use client';
import { useState } from 'react';

export default function CopyButton({ text }) {
  const [done, setDone] = useState(false);
  return (
    <button type="button" className="btn ghost" style={{ minHeight: 34, padding: '0 12px' }}
      onClick={async () => {
        try { await navigator.clipboard.writeText(text); setDone(true); setTimeout(() => setDone(false), 2000); } catch {}
      }}>
      {done ? 'تم النسخ ✓' : 'نسخ'}
    </button>
  );
}
