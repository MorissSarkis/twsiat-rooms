'use client';
import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { supabaseBrowser } from '@/lib/supabase-browser';

export default function Reset() {
  const sb = supabaseBrowser();
  const router = useRouter();
  const [p1, setP1] = useState('');
  const [p2, setP2] = useState('');
  const [err, setErr] = useState(null);
  const [busy, setBusy] = useState(false);

  async function submit(e) {
    e.preventDefault(); setErr(null);
    if (p1 !== p2) return setErr('كلمتين السر مش متطابقين');
    setBusy(true);
    const { error } = await sb.auth.updateUser({ password: p1 });
    setBusy(false);
    if (error) return setErr(error.message.includes('different') ? 'اختار كلمة سر مختلفة عن القديمة'
      : 'الرابط انتهى أو مش صالح. ارجع لصفحة الدخول واطلب رابط جديد.');
    router.push('/rooms'); router.refresh();
  }

  return (
    <main className="wrap" style={{ maxWidth: 420, paddingTop: 48 }}>
      <h1 style={{ fontSize: 24, textAlign: 'center' }}>كلمة سر جديدة</h1>
      <form onSubmit={submit} className="card grid">
        <label>كلمة السر الجديدة
          <input type="password" dir="ltr" value={p1} onChange={(e) => setP1(e.target.value)} required minLength={6} />
        </label>
        <label>أعد كتابتها
          <input type="password" dir="ltr" value={p2} onChange={(e) => setP2(e.target.value)} required minLength={6} />
        </label>
        {err && <div className="err">{err}</div>}
        <button className="btn" disabled={busy}>{busy ? '...' : 'احفظ وادخل'}</button>
      </form>
    </main>
  );
}
