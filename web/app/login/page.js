'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { supabaseBrowser } from '@/lib/supabase-browser';

export default function Login() {
  const sb = supabaseBrowser();
  const router = useRouter();
  const [mode, setMode] = useState('in'); // 'in' | 'up'
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [name, setName] = useState('');
  const [msg, setMsg] = useState(null);
  const [err, setErr] = useState(null);
  const [busy, setBusy] = useState(false);

  async function submit(e) {
    e.preventDefault(); setErr(null); setMsg(null); setBusy(true);
    if (mode === 'in') {
      const { error } = await sb.auth.signInWithPassword({ email, password });
      setBusy(false);
      if (error) return setErr('الإيميل أو كلمة السر غير صحيحة');
      router.push('/rooms'); router.refresh();
    } else {
      const { error } = await sb.auth.signUp({
        email, password,
        options: { data: { full_name: name }, emailRedirectTo: `${location.origin}/auth/callback` },
      });
      setBusy(false);
      if (error) return setErr(error.message.includes('Password') ? 'كلمة السر لازم تكون 6 أحرف على الأقل' : 'ما قدرنا ننشئ الحساب، جرّب مرة ثانية');
      setMsg('بعتنالك رسالة تأكيد على الإيميل. افتحها واضغط على الرابط لتفعيل حسابك.');
    }
  }

  async function google() {
    await sb.auth.signInWithOAuth({ provider: 'google', options: { redirectTo: `${location.origin}/auth/callback` } });
  }

  return (
    <main className="wrap" style={{ maxWidth: 420, paddingTop: 48 }}>
      <div style={{ textAlign: 'center', marginBottom: 24 }}>
        <h1 style={{ fontSize: 26 }}>غرفة التداول</h1>
        <div className="muted" style={{ fontSize: 14, lineHeight: 1.7 }}>
          مستويات يومية، أدوات وغرف توصيات خبراء موقع توصيات
        </div>
      </div>

      <div className="card grid">
        <div className="row" style={{ background: '#0F1624', borderRadius: 10, padding: 4 }}>
          <button type="button" className={`btn ${mode === 'in' ? '' : 'ghost'}`} style={{ flex: 1, border: 'none' }} onClick={() => setMode('in')}>تسجيل الدخول</button>
          <button type="button" className={`btn ${mode === 'up' ? '' : 'ghost'}`} style={{ flex: 1, border: 'none' }} onClick={() => setMode('up')}>حساب جديد</button>
        </div>

        <button type="button" className="btn ghost" onClick={google}>الدخول بحساب Google</button>
        <div className="muted" style={{ textAlign: 'center' }}>أو بالإيميل</div>

        <form onSubmit={submit} className="grid">
          {mode === 'up' && (
            <label>الاسم
              <input value={name} onChange={(e) => setName(e.target.value)} required />
            </label>
          )}
          <label>الإيميل
            <input type="email" dir="ltr" value={email} onChange={(e) => setEmail(e.target.value)} required />
          </label>
          <label>كلمة السر
            <input type="password" dir="ltr" value={password} onChange={(e) => setPassword(e.target.value)} required minLength={6} />
          </label>
          {err && <div className="err">{err}</div>}
          {msg && <div className="note">{msg}</div>}
          <button className="btn" disabled={busy}>{busy ? '...' : mode === 'in' ? 'دخول' : 'إنشاء حساب'}</button>
        </form>
      </div>
    </main>
  );
}
