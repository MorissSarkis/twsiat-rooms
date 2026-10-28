'use client';
import { useState } from 'react';
import { BROKERS } from '@/lib/brand';

// broker + account + "under our agency?" + WhatsApp (required when not under our agency)
export default function ActivationForm({ action, back, profile }) {
  const [hasIb, setHasIb] = useState(profile?.has_ib_account === false ? 'no' : 'yes');
  const yes = hasIb === 'yes';
  return (
    <form action={action} className="grid">
      <input type="hidden" name="back" value={back} />
      <div className="grid" style={{ gap: 8 }}>
        <label style={{ display: 'flex', flexDirection: 'row', alignItems: 'flex-start', gap: 10, cursor: 'pointer' }}>
          <input type="radio" name="has_ib" value="yes" checked={yes} onChange={() => setHasIb('yes')} style={{ width: 18, height: 18, flex: 'none', marginTop: 3 }} />
          <span>عندي حساب تداول تحت وكالة موقع توصيات</span>
        </label>
        <label style={{ display: 'flex', flexDirection: 'row', alignItems: 'flex-start', gap: 10, cursor: 'pointer' }}>
          <input type="radio" name="has_ib" value="no" checked={!yes} onChange={() => setHasIb('no')} style={{ width: 18, height: 18, flex: 'none', marginTop: 3 }} />
          <span>ما عندي حساب تحت وكالتكم (بدي مساعدة بفتح أو نقل حساب)</span>
        </label>
      </div>
      <label>شركة التداول{!yes && ' (إذا عندك حساب عند شركة)'}
        <select name="broker" defaultValue={profile?.broker || 'Exness'}>
          {BROKERS.map((b) => <option key={b}>{b}</option>)}
          <option value="">شركة ثانية / ما عندي حساب</option>
        </select>
      </label>
      <label>رقم حساب التداول (MT4 / MT5){!yes && ' — اختياري'}
        <input name="account" dir="ltr" inputMode="numeric" pattern="[0-9]{4,15}" title="أرقام بس" required={yes} defaultValue={profile?.broker_account || ''} />
      </label>
      <label>{yes ? 'رصيد حسابك الحالي بالدولار' : 'رصيد حسابك الحالي بالدولار — اختياري'}
        <input name="reported_balance" type="number" min="0" step="1" dir="ltr" inputMode="numeric" required={yes} placeholder="مثلاً 500" defaultValue={profile?.reported_balance ?? ''} />
        <span className="muted" style={{ fontSize: 12 }}>منحدد غرفتك حسبه: أقل من 1,000$ غرفة الحسابات الصغيرة، 1,000$ وأكثر الغرفة الكبيرة.</span>
      </label>
      <label>رقم واتساب مع المفتاح الدولي
        <input name="phone" type="tel" dir="ltr" placeholder="+971 50 123 4567" required defaultValue={profile?.phone || ''} autoComplete="tel" />
      </label>
      {!yes && <div className="note">فريقنا رح يتواصل معك على واتساب ويساعدك تفتح أو تنقل حسابك تحت وكالتنا، وبعدها التنبيهات والغرف مجانية إلك.</div>}
      <button className="btn">{yes ? 'أرسل طلب التفعيل' : 'أرسل، وتواصلوا معي'}</button>
    </form>
  );
}
