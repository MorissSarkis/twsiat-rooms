'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { supabaseBrowser } from '@/lib/supabase-browser';

function Msg({ m }) {
  if (!m) return null;
  return <div className={m.ok ? 'note ok' : 'err'}>{m.text}</div>;
}

export default function AccountForms({ email, pendingEmail, profile }) {
  const sb = supabaseBrowser();
  const router = useRouter();

  // name
  const [name, setName] = useState(profile.display_name);
  const [nameMsg, setNameMsg] = useState(null);
  async function saveName(e) {
    e.preventDefault();
    const v = name.trim();
    if (v.length < 2 || v.length > 40) return setNameMsg({ text: 'الاسم لازم يكون بين 2 و40 حرف' });
    const { data: { user } } = await sb.auth.getUser();
    const { error } = await sb.from('profiles').update({ display_name: v }).eq('id', user.id);
    setNameMsg(error ? { text: 'ما انحفظ، جرّب مرة تانية' } : { ok: true, text: 'انحفظ الاسم ✅' });
    if (!error) router.refresh();
  }

  // email
  const [newEmail, setNewEmail] = useState('');
  const [emailMsg, setEmailMsg] = useState(null);
  async function saveEmail(e) {
    e.preventDefault();
    const v = newEmail.trim().toLowerCase();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(v)) return setEmailMsg({ text: 'اكتب إيميل صحيح' });
    if (v === email) return setEmailMsg({ text: 'هاد نفس إيميلك الحالي' });
    const { error } = await sb.auth.updateUser({ email: v }, { emailRedirectTo: `${location.origin}/auth/callback?next=/account` });
    setEmailMsg(error
      ? { text: error.message.includes('already') ? 'هاد الإيميل مسجّل لحساب تاني' : 'ما زبط، جرّب بعد شوي' }
      : { ok: true, text: 'بعتنالك رابط تأكيد على الإيميل الجديد. اضغط عليه حتى يتغيّر (وممكن يوصلك تأكيد على القديم كمان).' });
  }

  // password
  const [p1, setP1] = useState('');
  const [p2, setP2] = useState('');
  const [show, setShow] = useState(false);
  const [passMsg, setPassMsg] = useState(null);
  async function savePass(e) {
    e.preventDefault();
    if (p1.length < 6) return setPassMsg({ text: 'كلمة السر لازم تكون 6 أحرف أو أكتر' });
    if (p1 !== p2) return setPassMsg({ text: 'كلمتين السر مش متطابقين' });
    const { error } = await sb.auth.updateUser({ password: p1 });
    if (error) return setPassMsg({ text: error.message.includes('different') ? 'اختار كلمة سر مختلفة عن القديمة' : 'ما زبط، اطلع وادخل من جديد وجرّب' });
    setP1(''); setP2(''); setPassMsg({ ok: true, text: 'تغيّرت كلمة السر ✅' });
  }

  // balance after a deposit
  const [bal, setBal] = useState('');
  const [note, setNote] = useState('');
  const [balMsg, setBalMsg] = useState(null);
  async function saveBal(e) {
    e.preventDefault();
    const v = Number(bal);
    if (!(v > 0)) return setBalMsg({ text: 'اكتب رصيدك الحالي بالدولار' });
    const { error } = await sb.rpc('report_balance', { p_balance: v, p_note: note });
    if (error) return setBalMsg({ text: error.message.includes('مفعّل') ? 'حسابك لسا مش مفعّل' : 'ما انبعت، جرّب مرة تانية' });
    setBal(''); setNote('');
    setBalMsg({ ok: true, text: profile.room !== 2 && v >= 1000
      ? 'وصلنا طلبك ✅ الفريق رح يتأكد من الرصيد وينقلك لغرفة الحسابات الكبيرة.'
      : 'وصلنا التحديث ✅ الفريق رح يتأكد من الرصيد ويحدّثه.' });
    router.refresh();
  }

  return (
    <main className="wrap grid" style={{ maxWidth: 620 }}>
      <h1>حسابي</h1>

      <form className="card grid" onSubmit={saveName}>
        <h2>الاسم</h2>
        <label>الاسم أو اللقب اللي بيظهر بالموقع<input value={name} onChange={(e) => setName(e.target.value)} maxLength={40} required /></label>
        <Msg m={nameMsg} />
        <button className="btn">احفظ الاسم</button>
      </form>

      {profile.ib_verified && (
        <form className="card grid" onSubmit={saveBal}>
          <h2>حسابي التداولي</h2>
          <div className="muted">
            {profile.broker || '—'} · <span className="ltr">{profile.broker_account || '—'}</span>
            {' · '}{profile.room === 2 ? 'غرفة الحسابات الكبيرة' : 'غرفة الحسابات الصغيرة'}
            {' · '}الرصيد المسجّل <span className="ltr">${profile.balance_usd ?? '—'}</span>
          </div>
          {profile.upgrade_requested_at && (
            <div className="note">طلبك قيد المراجعة: رصيد <span className="ltr">${profile.upgrade_balance}</span>{profile.upgrade_note ? ` · ${profile.upgrade_note}` : ''}</div>
          )}
          <div className="muted">أودعت مبلغ إضافي؟ اكتب رصيدك الحالي، والفريق بيتأكد وبيحدّثه{profile.room !== 2 ? '. إذا صار 1,000$ أو أكتر بننقلك لغرفة الحسابات الكبيرة.' : '.'}</div>
          <label>رصيدي الحالي بالدولار<input type="number" step="any" min="1" value={bal} onChange={(e) => setBal(e.target.value)} dir="ltr" required /></label>
          <label>ملاحظة (اختياري)<textarea value={note} onChange={(e) => setNote(e.target.value)} maxLength={500} placeholder="مثلاً: أودعت 500$ اليوم" /></label>
          <Msg m={balMsg} />
          <button className="btn">ابعت التحديث</button>
        </form>
      )}

      <form className="card grid" onSubmit={saveEmail}>
        <h2>الإيميل</h2>
        <div className="muted">إيميلك الحالي: <span className="ltr">{email}</span>{pendingEmail ? <> · بانتظار تأكيد <span className="ltr">{pendingEmail}</span></> : null}</div>
        <label>إيميل جديد<input type="email" value={newEmail} onChange={(e) => setNewEmail(e.target.value)} dir="ltr" required /></label>
        <Msg m={emailMsg} />
        <button className="btn">غيّر الإيميل</button>
      </form>

      <form className="card grid" onSubmit={savePass}>
        <h2>كلمة السر</h2>
        <label>كلمة سر جديدة<input type={show ? 'text' : 'password'} value={p1} onChange={(e) => setP1(e.target.value)} dir="ltr" required /></label>
        <label>أعد كتابتها<input type={show ? 'text' : 'password'} value={p2} onChange={(e) => setP2(e.target.value)} dir="ltr" required /></label>
        <label className="row" style={{ gap: 6 }}><input type="checkbox" checked={show} onChange={(e) => setShow(e.target.checked)} style={{ width: 'auto' }} /> أظهر كلمة السر</label>
        <Msg m={passMsg} />
        <button className="btn">غيّر كلمة السر</button>
      </form>
    </main>
  );
}
