'use client';
import { useState } from 'react';
import { useFormState } from 'react-dom';
import { setUsername, postIdea } from './actions';

export function UsernameForm() {
  const [state, action] = useFormState(setUsername, null);
  return (
    <form action={action} className="card grid">
      <b>اختار اسم مستخدم</b>
      <div className="muted">هاد الاسم اللي بيشوفه الأعضاء جنب أفكارك وأدائك. ما فيك تغيّره بعدين بسهولة، وما بيبيّن إيميلك ولا رقم حسابك.</div>
      <input name="username" dir="ltr" placeholder="gold_trader" required />
      {state?.error && <div className="err">{state.error}</div>}
      <button className="btn">احفظ</button>
    </form>
  );
}

export function PostForm({ symbols }) {
  const [state, action] = useFormState(postIdea, null);
  const [kind, setKind] = useState('LIMIT');
  return (
    <form action={action} className="card grid" key={state?.at || 0}>
      <b>انشر فكرة صفقة</b>
      <div className="grid g2">
        <label>الأصل
          <select name="symbol">{symbols.map((s) => <option key={s.code} value={s.code}>{s.name} {s.code}</option>)}</select>
        </label>
        <label>الاتجاه
          <select name="side" defaultValue="BUY"><option value="BUY">شراء</option><option value="SELL">بيع</option></select>
        </label>
        <label>نوع الأمر
          <select name="kind" value={kind} onChange={(e) => setKind(e.target.value)}>
            <option value="LIMIT">Limit (معلّق)</option>
            <option value="STOP">Stop (معلّق)</option>
            <option value="MARKET">بسعر السوق الآن</option>
          </select>
        </label>
        <label>سعر الدخول
          {kind === 'MARKET'
            ? <input disabled placeholder="السيرفر بيسجّل السعر لحاله" />
            : <input name="entry" type="number" step="any" required dir="ltr" />}
        </label>
        <label>وقف الخسارة<input name="stop" type="number" step="any" required dir="ltr" /></label>
        <label>الهدف<input name="tp" type="number" step="any" required dir="ltr" /></label>
      </div>
      <label>ليش؟ (اختياري، 280 حرف)<textarea name="note" maxLength={280} /></label>
      <div className="note">الفكرة بتنحفظ بالسعر والوقت من السيرفر، وما فيك تعدّلها أو تمسحها بعد النشر. الأمر المعلّق بينلغى إذا ما اتفعّل خلال 24 ساعة.</div>
      {state?.error && <div className="err">{state.error}</div>}
      {state?.ok && <div className="note" style={{ borderInlineStart: '3px solid var(--buy)' }}>انتشرت ✅</div>}
      <button className="btn">انشر</button>
    </form>
  );
}

export function CopyButton({ text }) {
  const [done, setDone] = useState(false);
  return (
    <button type="button" className="btn ghost" style={{ minHeight: 32, padding: '0 10px', fontSize: 13 }}
      onClick={async () => { try { await navigator.clipboard.writeText(text); setDone(true); setTimeout(() => setDone(false), 1500); } catch {} }}>
      {done ? 'انتسخت ✓' : 'انسخ التفاصيل'}
    </button>
  );
}
