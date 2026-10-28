import TopBar from '../TopBar';
import TelegramPrompt from '../TelegramPrompt';
import PushPrompt from '../PushPrompt';
import { currentUser } from '@/lib/supabase-server';
import { ROOM_AR } from '@/lib/format';
import ActivationBox, { ACT_ERRORS } from '../activation/box';
import { openAlerts } from '../alerts/actions';
import PhoneCard from '../phone/card';

export const dynamic = 'force-dynamic';

const timeLeft = (t) => { const ms = new Date(t) - Date.now(); const h = Math.max(0, Math.ceil(ms / 36e5)); const d = Math.floor(ms / 864e5);
  return d >= 2 ? `${d} يوم` : h > 1 ? `${h} ساعة` : 'أقل من ساعة'; };
const day = (t) => new Date(t).toLocaleDateString('en-GB', { timeZone: 'Asia/Riyadh' });

function TileBody({ icon, title, text, status, cta }) {
  return (
    <>
      <div className="tile-head"><span className="tile-icon">{icon}</span><b>{title}</b><span className="tile-arrow">‹</span></div>
      <div className="tile-text">{text}</div>
      <Status tone={status[0]}>{status[1]}</Status>
      <span className="tile-cta">{cta}</span>
    </>
  );
}

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

  const alertsStatus = a.reason === 'trial' ? ['ok', `✅ تجربة مجانية: باقي ${timeLeft(a.until)}`]
    : a.reason === 'ib' ? ['ok', '✅ مجانية إلك كعميل وكالة']
    : a.reason === 'paid' ? ['ok', `✅ مشترك لغاية ${day(a.until)}`]
    : a.reason === 'staff' ? ['ok', '✅ حساب الفريق']
    : a.reason === 'employee' ? ['ok', '✅ مجانية: موظف']
    : a.reason === 'vip' ? ['ok', '✅ مجانية إلك']
    : a.reason === 'trial_over' ? ['bad', 'انتهت التجربة المجانية (14 يوم)']
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
 {searchParams?.ok === 'phone' && <div className="card hl"><b>انحفظ رقمك ✅</b></div>}
        {!profile.phone && profile.role === 'client' && <PhoneCard />}
        {searchParams?.ok === 'act' && <div className="card hl"><b>وصلنا طلبك ✅</b><div className="muted" style={{ marginTop: 4 }}>رح نتواصل معك قريباً.</div></div>}

        {/* two big tappable tiles: the whole tile is the button */}
        {a.ok ? (
          <form action={openAlerts}>
            <button className="tile tile-alerts">
              <TileBody icon="🔔" title="تنبيهات البيفوت" text="إشعار على موبايلك لما يوصل السعر لمستويات الدعم والمقاومة اليومية، على 57 أداة."
                status={alertsStatus} cta="افتح تطبيق التنبيهات" />
            </button>
          </form>
        ) : (
          <a className="tile tile-alerts" href={verified ? '/alerts' : '#activate'}>
            <TileBody icon="🔔" title="تنبيهات البيفوت" text="إشعار على موبايلك لما يوصل السعر لمستويات الدعم والمقاومة اليومية، على 57 أداة."
              status={alertsStatus} cta={verified ? 'افتح التنبيهات' : 'فعّلها مجاناً'} />
          </a>
        )}
        <a className="tile tile-rooms" href={verified ? '/rooms' : '#activate'}>
          <TileBody icon="💬" title="غرف توصيات الخبراء" text="أفكار تداول جاهزة: الدخول، الستوب، الأهداف، وحجم اللوت المناسب لحسابك."
            status={roomsStatus} cta={verified ? 'ادخل غرفتك' : roomsStatus[0] === 'wait' ? 'شوف حالة طلبك' : 'افتح الغرف مجاناً'} />
        </a>

        {!verified && (
          <a className="scroll-hint" href="#activate" aria-label="انزل لتحت">
            <span>خطوة وحدة وكل شي بيصير مجاني</span>
            <span className="chev">⌄</span>
          </a>
        )}

        <PushPrompt />
        {verified ? <TelegramPrompt link={tgLink} /> : (
          <>
            <div id="activate" style={{ marginTop: 6, scrollMarginTop: 16 }}>
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
