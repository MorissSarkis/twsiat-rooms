import TopBar from '../TopBar';
import TelegramPrompt from '../TelegramPrompt';
import { currentUser } from '@/lib/supabase-server';
import { ROOM_AR } from '@/lib/format';
import ActivationBox, { ACT_ERRORS } from '../activation/box';
import { openAlerts } from '../alerts/actions';

export const dynamic = 'force-dynamic';

const hoursLeft = (t) => { const h = Math.max(0, Math.ceil((new Date(t) - Date.now()) / 36e5)); return h > 1 ? `${h} ساعة` : 'أقل من ساعة'; };
const day = (t) => new Date(t).toLocaleDateString('en-GB', { timeZone: 'Asia/Riyadh' });

function Status({ tone, children }) {
  const c = { ok: 'var(--buy)', wait: 'var(--gold)', off: 'var(--muted)', bad: 'var(--sell)' }[tone];
  return <div style={{ color: c, fontWeight: 600, fontSize: 14, margin: '10px 0 2px' }}>{children}</div>;
}

// One home page after sign-in: what you have, what each thing is, and the one step that makes it all free
export default async function Home({ searchParams }) {
  const { sb, user, profile } = await currentUser();
  if (!profile) return null;
  const [{ data: access }, { data: tgLink }] = await Promise.all([sb.rpc('my_alerts_access'), sb.rpc('my_telegram_link')]);
  const a = access || {};
  const name = (profile.display_name || '').trim();
  const verified = profile.ib_verified;
  const err = ACT_ERRORS[searchParams?.e];

  const alertsStatus = a.reason === 'trial' ? ['ok', `✅ تجربة مجانية: باقي ${hoursLeft(a.until)}`]
    : a.reason === 'ib' ? ['ok', '✅ مجانية إلك كعميل وكالة']
    : a.reason === 'paid' ? ['ok', `✅ مشترك لغاية ${day(a.until)}`]
    : a.reason === 'staff' ? ['ok', '✅ حساب الفريق']
    : a.reason === 'trial_over' ? ['bad', 'انتهت التجربة المجانية (48 ساعة)']
    : a.reason === 'expired' ? ['bad', `انتهى الاشتراك ${a.until ? day(a.until) : ''}`]
    : ['off', 'مش مفعّلة'];
  const roomsStatus = verified ? ['ok', `✅ مفعّلة: ${ROOM_AR[profile.room || 1]}`]
    : profile.activation_requested_at && !profile.activation_rejected_at ? ['wait', '⏳ طلبك قيد المراجعة']
    : ['off', '🔒 لعملاء وكالة موقع توصيات'];

  return (
    <>
      <TopBar profile={profile} />
      <main className="wrap grid" style={{ maxWidth: 620 }}>
        <div>
          <h1 style={{ marginBottom: 4 }}>أهلاً{name ? ` ${name}` : ''} 👋</h1>
          <div className="muted">كل خدماتك بمكان واحد.</div>
        </div>
        {err && <div className="err">{err}</div>}
        {searchParams?.ok === 'act' && <div className="card hl"><b>وصلنا طلبك ✅</b><div className="muted" style={{ marginTop: 4 }}>رح نتواصل معك قريباً.</div></div>}

        <div className="card grid" style={{ gap: 6 }}>
          <b style={{ fontSize: 18 }}>🔔 تنبيهات البيفوت</b>
          <div className="muted" style={{ lineHeight: 1.7 }}>إشعار على موبايلك لما يوصل السعر لمستويات الدعم والمقاومة اليومية، على 57 أداة.</div>
          <Status tone={alertsStatus[0]}>{alertsStatus[1]}</Status>
          {a.ok
            ? <form action={openAlerts}><button className="btn green" style={{ width: '100%', marginTop: 6 }}>افتح تطبيق التنبيهات</button></form>
            : <a className="btn" style={{ marginTop: 6 }} href="/alerts">فعّلها مجاناً أو اشترك</a>}
        </div>

        <div className="card grid" style={{ gap: 6 }}>
          <b style={{ fontSize: 18 }}>💬 غرف توصيات الخبراء</b>
          <div className="muted" style={{ lineHeight: 1.7 }}>أفكار تداول جاهزة: الدخول، الستوب، الأهداف، وحجم اللوت المناسب لحسابك.</div>
          <Status tone={roomsStatus[0]}>{roomsStatus[1]}</Status>
          {verified && <a className="btn green" style={{ marginTop: 6 }} href="/rooms">ادخل غرفتك</a>}
        </div>

        {verified ? <TelegramPrompt link={tgLink} /> : (
          <>
            <div style={{ marginTop: 6 }}>
              <h2 style={{ marginBottom: 4 }}>⭐ خلّي كل شي مجاني</h2>
              <div className="muted" style={{ lineHeight: 1.8 }}>
                عندك حساب تداول تحت وكالة موقع توصيات؟ التنبيهات والغرف مجانية إلك. ما عندك؟ اترك رقم واتساب ومنساعدك.
              </div>
            </div>
            <ActivationBox profile={profile} user={user} back="/home" />
          </>
        )}

        <div className="row" style={{ justifyContent: 'center', gap: 18, marginTop: 6 }}>
          <a className="muted" href="/community">غرفة المجتمع</a>
          <a className="muted" href="/levels">المستويات اليومية</a>
          <a className="muted" href="/record">سجل الأداء</a>
        </div>
      </main>
    </>
  );
}
