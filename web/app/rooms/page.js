import TopBar from '../TopBar';
import { currentUser } from '@/lib/supabase-server';
import { DISCLAIMER, DISCLAIMER_VERSION } from '@/lib/disclaimer';
import { fmt, lotFor, STATE_AR, ROOM_AR, symName } from '@/lib/format';
import { requestActivation, acceptDisclaimer } from './actions';

export const dynamic = 'force-dynamic';

export default async function Rooms() {
  const { sb, profile } = await currentUser();
  if (!profile) return null;

  // 1) not verified yet → activation
  if (!profile.ib_verified) {
    return (
      <>
        <TopBar profile={profile} />
        <main className="wrap grid" style={{ maxWidth: 560 }}>
          <h1>فعّل غرف الخبراء</h1>
          <div className="muted" style={{ lineHeight: 1.8 }}>
            غرف توصيات خبراء موقع توصيات متاحة لعملائنا. أدخل رقم حساب التداول مرة وحدة بس عشان نتأكد إنه مفتوح تحت وكالتنا.
            رقم الحساب ما بيظهر لأي حد.
          </div>
          {profile.activation_requested_at ? (
            <div className="card hl">
              <b>طلبك وصلنا ✅</b>
              <div className="muted" style={{ marginTop: 6 }}>فريقنا بيراجعه وبيفعّل حسابك خلال وقت قصير. رح يوصلك إيميل لما يتفعّل.</div>
            </div>
          ) : (
            <form action={requestActivation} className="card grid">
              <label>الوسيط
                <select name="broker" defaultValue="Exness"><option>Exness</option><option>غير ذلك</option></select>
              </label>
              <label>رقم حساب التداول (MT4 / MT5)
                <input name="account" dir="ltr" inputMode="numeric" required />
              </label>
              <button className="btn">أرسل طلب التفعيل</button>
            </form>
          )}
          <div className="note">ما عندك حساب تحت وكالتنا؟ تواصل مع فريق موقع توصيات لفتح حساب.</div>
        </main>
      </>
    );
  }

  const room = profile.room || 1;

  // 2) verified → disclaimer for the room
  const { data: consent } = await sb.from('consents').select('id').eq('user_id', profile.id).eq('room', room).eq('version', DISCLAIMER_VERSION).maybeSingle();
  if (!consent) {
    return (
      <>
        <TopBar profile={profile} />
        <main className="wrap grid" style={{ maxWidth: 620 }}>
          <h1>{ROOM_AR[room]}</h1>
          <div className="card grid">
            <b>قبل الدخول، اقرأ ووافق:</b>
            <ol style={{ margin: 0, paddingInlineStart: 20, lineHeight: 1.9, color: 'var(--soft)', fontSize: 14 }}>
              {DISCLAIMER[room].map((t, i) => <li key={i}>{t}</li>)}
            </ol>
            <form action={acceptDisclaimer}>
              <input type="hidden" name="room" value={room} />
              <button className="btn" style={{ width: '100%' }}>قرأت وأوافق، ادخل الغرفة</button>
            </form>
          </div>
        </main>
      </>
    );
  }

  // 3) room signals
  const { data: signals } = await sb.from('signals').select('*').contains('rooms', [room]).order('published_at', { ascending: false }).limit(30);

  return (
    <>
      <TopBar profile={profile} />
      <main className="wrap grid">
        <div className="card hl">
          <div className="muted">غرفتك</div>
          <b style={{ fontSize: 17 }}>{ROOM_AR[room]}</b>
          {profile.balance_usd && <div className="muted" style={{ marginTop: 4 }}>الرصيد المسجّل: <span className="ltr">${fmt(profile.balance_usd, 0)}</span></div>}
        </div>

        <h2>التوصيات</h2>
        {(!signals || signals.length === 0) && <div className="card muted">ما في توصيات منشورة لهلأ. رح يوصلك إشعار أول ما تنزل توصية جديدة.</div>}
        {signals?.map((s) => {
          const lot = lotFor(profile.balance_usd, 1, s.risk_usd_001);
          return (
            <div key={s.id} className="card grid">
              <div className="row" style={{ justifyContent: 'space-between' }}>
                <div className="row">
                  <b>{symName(s.symbol)}</b>
                  <span className={`badge ${s.side === 'BUY' ? 'buy' : 'sell'}`}>{s.side === 'BUY' ? 'شراء' : 'بيع'}</span>
                  <span className="muted">{s.order_type.includes('LIMIT') ? 'أمر معلق' : s.order_type.includes('STOP') ? 'أمر ستوب' : 'بسعر السوق'}</span>
                </div>
                <span className="muted ltr">{new Date(s.published_at).toLocaleString('en-GB', { timeZone: 'Asia/Riyadh', dateStyle: 'short', timeStyle: 'short' })}</span>
              </div>
              <div className="kv">
                <div><span className="muted">الدخول</span><b>{fmt(s.entry)}</b></div>
                <div><span className="muted">وقف الخسارة</span><b className="bad">{fmt(s.stop_loss)}</b></div>
                <div><span className="muted">الهدف 1</span><b className="ok">{fmt(s.tp1)}</b></div>
                <div><span className="muted">الهدف 2</span><b className="ok">{fmt(s.tp2)}</b></div>
              </div>
              <div className="row muted" style={{ justifyContent: 'space-between' }}>
                <span>المخاطرة: <span className="ltr">${fmt(s.risk_usd_001, 1)}</span> لكل 0.01 لوت</span>
                <span style={{ color: 'var(--gold)' }}>
                  {lot == null ? '' : lot >= 0.01 ? `لحسابك بمخاطرة 1%: ${lot.toFixed(2)} لوت` : 'المخاطرة أكبر من 1% من حسابك حتى بأصغر لوت — استخدم حساب سنت'}
                </span>
              </div>
              <div className="row" style={{ justifyContent: 'space-between' }}>
                <span className="muted">الإدارة: سكّر نص الصفقة عند الهدف 1 وانقل الستوب للدخول، أو اكتفِ بالهدف 1</span>
                <span className={s.state === 'sl' ? 'bad' : s.state.startsWith('tp') ? 'ok' : 'muted'}>{STATE_AR[s.state] || s.state}</span>
              </div>
            </div>
          );
        })}
      </main>
    </>
  );
}
