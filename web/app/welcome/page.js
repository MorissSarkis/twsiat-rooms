'use client';
import { useEffect, useState } from 'react';
import { supabaseBrowser } from '@/lib/supabase-browser';
import { LOGO_URL, wa } from '@/lib/brand';

// After sign-up: a clear "we got your details" page instead of a note under the form
const INBOX = [
  [/@(gmail|googlemail)\./i, 'Gmail', 'https://mail.google.com/mail/u/0/#search/twsiat'],
  [/@(outlook|hotmail|live|msn)\./i, 'Outlook', 'https://outlook.live.com/mail/0/'],
  [/@yahoo\./i, 'Yahoo Mail', 'https://mail.yahoo.com/'],
  [/@(icloud|me|mac)\./i, 'iCloud Mail', 'https://www.icloud.com/mail'],
];

export default function Welcome() {
  const [email, setEmail] = useState('');
  const [wait, setWait] = useState(0);
  const [msg, setMsg] = useState(null);
  useEffect(() => { setEmail(new URLSearchParams(location.search).get('email') || ''); }, []);
  useEffect(() => { if (wait > 0) { const id = setTimeout(() => setWait(wait - 1), 1000); return () => clearTimeout(id); } }, [wait]);
  const inbox = INBOX.find(([re]) => re.test(email));

  async function resend() {
    setMsg(null);
    const { error } = await supabaseBrowser().auth.resend({ type: 'signup', email, options: { emailRedirectTo: `${location.origin}/auth/callback?next=/home` } });
    setMsg(error ? 'ما قدرنا نبعت هلأ. استنى دقيقة وجرّب مرة ثانية.' : 'بعتناها مرة ثانية ✅');
    setWait(60);
  }

  return (
    <main className="wrap" style={{ maxWidth: 440, paddingTop: 48 }}>
      <div style={{ textAlign: 'center' }}>
        <img src={LOGO_URL} alt="موقع توصيات" width={72} height={72} className="logo" style={{ borderRadius: 18 }} />
        <div style={{ fontSize: 54, lineHeight: 1, margin: '18px 0 6px' }}>🎉</div>
        <h1 style={{ fontSize: 26, margin: '6px 0' }}>أهلاً فيك! وصلتنا معلوماتك</h1>
        <div className="muted" style={{ fontSize: 15, lineHeight: 1.8 }}>خطوة وحدة بس وبتدخل.</div>
      </div>

      <div className="card hl grid" style={{ marginTop: 22 }}>
        <div className="row" style={{ alignItems: 'flex-start', flexWrap: 'nowrap', gap: 12 }}>
          <div style={{ fontSize: 30, lineHeight: 1 }}>📩</div>
          <div>
            <b style={{ fontSize: 17 }}>أكّد إيميلك</b>
            <div className="muted" style={{ marginTop: 4, lineHeight: 1.8 }}>
              بعتنالك رسالة على {email ? <b className="ltr" style={{ color: 'var(--text)' }}>{email}</b> : 'إيميلك'}.
              افتحها واضغط <b>«تأكيد الحساب»</b>، وبتدخل مباشرة على حسابك وبتبلّش تجربتك المجانية للتنبيهات.
            </div>
          </div>
        </div>
        {inbox && <a className="btn" href={inbox[2]} target="_blank" rel="noopener">افتح {inbox[1]}</a>}
        <div className="note">ما لقيتها؟ شوف مجلد <b>Spam</b> أو <b>الترويج / Promotions</b>.</div>
        {email && (
          <button type="button" className="btn ghost" disabled={wait > 0} onClick={resend}>
            {wait > 0 ? `إعادة الإرسال بعد ${wait} ثانية` : 'ما وصلتني، ابعتوها مرة ثانية'}
          </button>
        )}
        {msg && <div className="muted" style={{ textAlign: 'center' }}>{msg}</div>}
      </div>

      <div className="grid" style={{ marginTop: 16, gap: 10 }}>
        <a className="btn ghost" href="/login">أكّدت إيميلي، بدي أدخل</a>
        <a className="muted" style={{ textAlign: 'center' }} href={wa('مرحبا، سجّلت بموقع توصيات وما وصلني إيميل التأكيد. إيميلي: ' + email)} target="_blank" rel="noopener">بحاجة مساعدة؟ راسلنا على واتساب</a>
      </div>
    </main>
  );
}
