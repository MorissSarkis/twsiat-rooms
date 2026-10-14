'use client';
import { useFormState } from 'react-dom';
import { submitSignal } from './actions';

export default function NewSignal() {
  const [state, action] = useFormState(submitSignal, null);
  return (
    <main className="wrap grid" style={{ maxWidth: 620 }}>
      <a href="/admin">← الباك أوفيس</a>
      <h1>توصية جديدة من المحلل</h1>
      <div className="muted" style={{ lineHeight: 1.8 }}>
        السيستم بيفحص التوصية تلقائياً (الاتجاه اليومي، اتجاه الساعة، حجم الستوب، مسافة الهدف 1) وبتروح للمدير مع النتيجة.
      </div>
      <form action={action} className="card grid">
        <div className="grid g2">
          <label>الأصل
            <select name="symbol" defaultValue="XAUUSD"><option value="XAUUSD">الذهب XAUUSD</option></select>
          </label>
          <label>الاتجاه
            <select name="side" defaultValue="BUY"><option value="BUY">شراء</option><option value="SELL">بيع</option></select>
          </label>
          <label>نوع الأمر
            <select name="kind" defaultValue="LIMIT"><option value="LIMIT">Limit (معلق)</option><option value="STOP">Stop (معلق)</option><option value="MARKET">بسعر السوق</option></select>
          </label>
          <label>صالح لمدة (ساعات)
            <input name="hours" type="number" defaultValue="12" dir="ltr" />
          </label>
          <label>سعر الدخول<input name="entry" type="number" step="any" required dir="ltr" /></label>
          <label>وقف الخسارة<input name="stop" type="number" step="any" required dir="ltr" /></label>
          <label>الهدف 1<input name="tp1" type="number" step="any" required dir="ltr" /></label>
          <label>الهدف 2<input name="tp2" type="number" step="any" dir="ltr" /></label>
        </div>
        <label>ملاحظة المحلل (اختياري)<textarea name="note" /></label>
        {state?.error && <div className="err">{state.error}</div>}
        <button className="btn">أرسل للفحص والموافقة</button>
      </form>
    </main>
  );
}
