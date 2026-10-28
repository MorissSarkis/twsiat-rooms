import ActivationBox, { ACT_ERRORS } from '../activation/box';
import TopBar from '../TopBar';
import TelegramPrompt from '../TelegramPrompt';
import PushPrompt from '../PushPrompt';
import { currentUser } from '@/lib/supabase-server';
import { DISCLAIMER, DISCLAIMER_VERSION } from '@/lib/disclaimer';
import { fmt, lotFor, STATE_AR, ROOM_AR, symName } from '@/lib/format';
import { acceptDisclaimer, requestUpgrade } from './actions';
import { wa } from '@/lib/brand';

export const dynamic = 'force-dynamic';

export default async function Rooms({ searchParams }) {
  const { sb, user, profile } = await currentUser();
  if (!profile) return null;
  const { data: tgLink } = await sb.rpc('my_telegram_link');

  const staff = ['analyst', 'manager', 'admin'].includes(profile.role);

  // 1) not verified yet → activation
  if (!profile.ib_verified && !staff) {
    return (
      <>
        <TopBar profile={profile} />
        <main className="wrap grid" style={{ maxWidth: 560 }}>
          <h1>فعّل غرف الخبراء</h1>
          <div className="muted" style={{ lineHeight: 1.8 }}>
            غرف توصيات خبراء موقع توصيات مجانية لعملاء وكالتنا. أدخل رقم حساب التداول مرة وحدة بس عشان نتأكد إنه مفتوح تحت وكالتنا،
            أو اطلب مساعدتنا بفتح أو نقل حساب. رقم الحساب ما بيظهر لأي حد.
          </div>
          {ACT_ERRORS[searchParams?.e] && <div className="err">{ACT_ERRORS[searchParams.e]}</div>}
          <ActivationBox profile={profile} user={user} back="/rooms" />
        </main>
      </>
    );
  }

  const myRoom = staff ? 2 : (profile.room || 1);
  const room = myRoom;
  const view = ['1', '2'].includes(String(searchParams?.room)) ? Number(searchParams.room) : myRoom;
  const Tabs = () => (
    <div className="roomtabs">
      {[1, 2].map((r) => (
        <a key={r} href={`/rooms?room=${r}`} className={view === r ? 'on' : ''}>
          {!staff && r > myRoom && '🔒 '}{r === 1 ? 'الحسابات الصغيرة' : 'الحسابات الكبيرة'}
          <span>{r === 1 ? 'أقل من 1,000$' : '1,000$ وأكثر'}</span>
        </a>
      ))}
    </div>
  );

  // 2) verified → disclaimer for the member's own room (staff skip it)
  const { data: consent } = staff ? { data: true } : await sb.from('consents').select('id').eq('user_id', profile.id).eq('room', room).eq('version', DISCLAIMER_VERSION).maybeSingle();
  if (!consent) {
    return (
      <>
        <TopBar profile={profile} />
        <main className="wrap grid" style={{ maxWidth: 620 }}>
          <PushPrompt />
        <TelegramPrompt link={tgLink} />
          <div className="card hl"><b>تم تفعيل حسابك ✅</b><div className="muted" style={{ marginTop: 4 }}>أهلاً فيك! خطوة أخيرة وبتدخل غرفتك.</div></div>
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

  // 3) a room above the member's level → locked, with an upgrade request
  if (!staff && view > myRoom) {
    const { data: tz } = await sb.rpc('room_teaser', { p_room: view });
    return (
      <>
        <TopBar profile={profile} />
        <main className="wrap grid" style={{ maxWidth: 620 }}>
          <Tabs />
          <div className="card hl grid" style={{ gap: 10 }}>
            <b style={{ fontSize: 18 }}>🔒 غرفة الحسابات الكبيرة · 1,000$ وأكثر</b>
            <div className="muted" style={{ lineHeight: 1.8 }}>
              هالغرفة لحسابات رصيدها 1,000$ أو أكثر. توصياتها فيها أهداف أبعد وإدارة صفقة مناسبة للحسابات الأكبر.
              {profile.balance_usd != null && <> رصيدك المسجّل عنا: <b className="ltr" style={{ color: 'var(--text)' }}>${fmt(profile.balance_usd, 0)}</b>.</>}
            </div>
            {tz && <div className="row" style={{ gap: 16 }}>
              <span>نزل فيها آخر 30 يوم: <b>{tz.last30}</b> توصية</span>
              {tz.closed > 0 && <span>نسبة النجاح: <b>{fmt((100 * tz.wins) / tz.closed, 0)}%</b> من {tz.closed}</span>}
            </div>}
          </div>
          {profile.upgrade_requested_at ? (
            <div className="card grid" style={{ gap: 6 }}>
              <b>طلب الترقية وصلنا ✅</b>
              <div className="muted">رح نتأكد من رصيدك (<span className="ltr">${fmt(profile.upgrade_balance, 0)}</span>) وننقلك للغرفة الكبيرة خلال وقت قصير.</div>
            </div>
          ) : (
            <form action={requestUpgrade} className="card grid">
              <b>زِد رصيد حسابك لـ 1,000$ أو أكثر وادخل الغرفة</b>
              <div className="muted">بعد ما تودع، اكتب رصيدك الحالي واضغط الزر، ومنحدّث غرفتك بعد ما نتأكد.</div>
              <label>رصيد حسابك الحالي بالدولار
                <input name="balance" type="number" min="1000" step="1" dir="ltr" inputMode="numeric" required placeholder="1000" />
              </label>
              <button className="btn">أودعت، انقلني للغرفة الكبيرة</button>
            </form>
          )}
          <a className="btn ghost" href={wa('مرحبا، بدي أزيد رصيد حسابي وأنتقل لغرفة الحسابات الكبيرة.')} target="_blank" rel="noopener">عندك سؤال؟ راسلنا على واتساب</a>
        </main>
      </>
    );
  }

  // 4) room signals
  const { data: signals } = await sb.from('signals').select('*').contains('rooms', [view]).order('published_at', { ascending: false }).limit(30);

  return (
    <>
      <TopBar profile={profile} />
      <main className="wrap grid">
        <PushPrompt />
        <TelegramPrompt link={tgLink} />
        <Tabs />
        <div className="card hl">
          <div className="muted">{staff ? 'عرض الفريق' : view === myRoom ? 'غرفتك' : 'عم تشوف'}</div>
          <b style={{ fontSize: 17 }}>{ROOM_AR[view]}</b>
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
                  {s.credit_username && <span className="muted">💡 فكرة من العضو <span className="ltr">@{s.credit_username}</span></span>}
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
