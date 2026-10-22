'use client';
import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { supabaseBrowser } from '@/lib/supabase-browser';
import { LOGO_URL } from '@/lib/brand';

export default function Login() {
  const sb = supabaseBrowser();
  const router = useRouter();
  const [mode, setMode] = useState('in'); // 'in' | 'up' | 'reset'
  const googleOn = process.env.NEXT_PUBLIC_GOOGLE_LOGIN === '1';
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [name, setName] = useState('');
  const [msg, setMsg] = useState(null);
  const [err, setErr] = useState(null);
  const [busy, setBusy] = useState(false);
  const [show, setShow] = useState(false);
  const [next, setNext] = useState('/rooms');   // where to go after login (only same-site paths)
  useEffect(() => {
    const n = new URLSearchParams(location.search).get('next');
    if (n && /^\/[a-z]/.test(n)) setNext(n);
    if (new URLSearchParams(location.search).get('e') === 'link') setErr('رابط التفعيل انتهى أو استُعمل قبل. سجّل دخول، أو اطلب رابط جديد.');
  }, []);

  async function submit(e) {
    e.preventDefault(); setErr(null); setMsg(null); setBusy(true);
    if (mode === 'reset') {
      await sb.auth.resetPasswordForEmail(email, { redirectTo: `${location.origin}/auth/callback?next=/reset` });
      setBusy(false);
      return setMsg('إذا الإيميل مسجّل عنا، رح توصلك رسالة فيها رابط لتغيير كلمة السر.');
    }
    if (mode === 'in') {
      const { error } = await sb.auth.signInWithPassword({ email, password });
      setBusy(false);
      if (error) return setErr('الإيميل أو كلمة السر غير صحيحة');
      router.push(next); router.refresh();
    } else {
      const { error } = await sb.auth.signUp({
        email, password,
        options: { data: { full_name: name }, emailRedirectTo: `${location.origin}/auth/callback?next=${encodeURIComponent(next)}` },
      });
      setBusy(false);
      if (error) return setErr(error.message.includes('Password') ? 'كلمة السر لازم تكون 6 أحرف على الأقل' : 'ما قدرنا ننشئ الحساب، جرّب مرة ثانية');
      setMsg('بعتنالك رسالة تأكيد على الإيميل. افتحها واضغط على الرابط لتفعيل حسابك.');
    }
  }

  async function google() {
    await sb.auth.signInWithOAuth({ provider: 'google', options: { redirectTo: `${location.origin}/auth/callback?next=${encodeURIComponent(next)}` } });
  }

  return (
    <main className="wrap" style={{ maxWidth: 420, paddingTop: 48 }}>
      <div style={{ textAlign: 'center', marginBottom: 24 }}>
        <a href="https://www.twsiat.com"><img src={LOGO_URL} alt="موقع توصيات" width={84} height={84} className="logo" style={{ borderRadius: 18, marginBottom: 12 }} /></a>
        <h1 style={{ fontSize: 26 }}>غرفة التوصيات</h1>
        <div className="muted" style={{ fontSize: 14, lineHeight: 1.7 }}>
          مستويات يومية، أدوات وغرف توصيات خبراء موقع توصيات
        </div>
      </div>

      <div className="card grid">
        <div className="row" style={{ background: '#0F1624', borderRadius: 10, padding: 4 }}>
          <button type="button" className={`btn ${mode === 'in' ? '' : 'ghost'}`} style={{ flex: 1, border: 'none' }} onClick={() => setMode('in')}>تسجيل الدخول</button>
          <button type="button" className={`btn ${mode === 'up' ? '' : 'ghost'}`} style={{ flex: 1, border: 'none' }} onClick={() => setMode('up')}>حساب جديد</button>
        </div>

        {googleOn && mode !== 'reset' && <>
          <button type="button" className="btn ghost" onClick={google}>الدخول بحساب Google</button>
          <div className="muted" style={{ textAlign: 'center' }}>أو بالإيميل</div>
        </>}
        {mode === 'reset' && <div className="muted">اكتب إيميلك وبنبعتلك رابط لتغيير كلمة السر.</div>}

        <form onSubmit={submit} className="grid">
          {mode === 'up' && (
            <label>الاسم
              <input value={name} onChange={(e) => setName(e.target.value)} required />
            </label>
          )}
          <label>الإيميل
            <input type="email" dir="ltr" value={email} onChange={(e) => setEmail(e.target.value)} required />
          </label>
          {mode !== 'reset' && (
            <label>كلمة السر
              <div className="pw">
                <input type={show ? 'text' : 'password'} dir="ltr" value={password} onChange={(e) => setPassword(e.target.value)} required minLength={6} autoComplete={mode === 'up' ? 'new-password' : 'current-password'} />
                <button type="button" className="eye" onClick={() => setShow(!show)} aria-label={show ? 'إخفاء كلمة السر' : 'إظهار كلمة السر'}>{show ? 'إخفاء' : 'إظهار'}</button>
              </div>
            </label>
          )}
          {err && <div className="err">{err}</div>}
          {msg && <div className="note">{msg}</div>}
          <button className="btn" disabled={busy}>{busy ? '...' : mode === 'in' ? 'دخول' : mode === 'up' ? 'إنشاء حساب' : 'ابعتلي الرابط'}</button>
        </form>
        {mode === 'in' && <button type="button" className="btn ghost" style={{ border: 'none' }} onClick={() => { setMode('reset'); setErr(null); setMsg(null); }}>نسيت كلمة السر؟</button>}
        {mode === 'reset' && <button type="button" className="btn ghost" style={{ border: 'none' }} onClick={() => { setMode('in'); setErr(null); setMsg(null); }}>رجوع لتسجيل الدخول</button>}
      </div>
    </main>
  );
}
