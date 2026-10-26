import { savePhone } from './actions';

// Shown on the home page until the member has a WhatsApp number on file
export default function PhoneCard() {
  return (
    <form action={savePhone} id="phone" className="card hl grid" style={{ scrollMarginTop: 16 }}>
      <div>
        <b style={{ fontSize: 17 }}>📱 خطوة أخيرة: رقم واتساب</b>
        <div className="muted" style={{ marginTop: 4, lineHeight: 1.8 }}>
          منحتاجه عشان نتأكد من حسابك عند شركة التداول ونتواصل معك. بعدها بتفتحلك التنبيهات.
        </div>
      </div>
      <input name="phone" type="tel" dir="ltr" required placeholder="+971 50 123 4567" autoComplete="tel"
        pattern="(\+|00)[1-9][0-9 \-]{7,18}" title="مع المفتاح الدولي، مثلاً +971501234567" />
      <button className="btn">احفظ وكمّل</button>
    </form>
  );
}
