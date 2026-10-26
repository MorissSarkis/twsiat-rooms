import TopBar from '../TopBar';
import { currentUser } from '@/lib/supabase-server';
import { wa } from '@/lib/brand';
import ActivationBox, { ACT_ERRORS } from '../activation/box';
import { openAlerts, submitPayment } from './actions';
import CopyButton from './copy';

export const dynamic = 'force-dynamic';

const ERRORS = {
  access: 'ما عندك اشتراك فعّال بالتنبيهات حالياً.',
  txid: 'رقم العملية (TXID) غير صحيح. انسخه كامل من المحفظة أو من موقع البلوكتشين.',
  network: 'اختار الشبكة اللي حوّلت عليها.',
  pending: 'عندك طلبات دفع لسا قيد المراجعة. استنى لنراجعها، أو راسلنا على واتساب.',
  used: 'رقم العملية هاد مسجّل قبل.',
  pay: 'ما قدرنا نسجّل الدفعة، جرّب مرة ثانية أو راسلنا على واتساب.',
};
const STATUS_AR = { pending: 'قيد المراجعة', approved: 'تمت الموافقة ✓', rejected: 'مرفوضة' };
const day = (t) => new Date(t).toLocaleDateString('en-GB', { timeZone: 'Asia/Riyadh' });
const hoursLeft = (t) => { const h = Math.max(0, Math.ceil((new Date(t) - Date.now()) / 36e5)); return h > 1 ? `${h} ساعة` : 'أقل من ساعة'; };

export default async function Alerts({ searchParams }) {
  const { sb, user, profile } = await currentUser();
  if (!profile) return null;
  const [{ data: access }, { data: plan }, { data: payments }] = await Promise.all([
    sb.rpc('my_alerts_access'),
    sb.rpc('alerts_plan'),
    sb.from('alerts_payments').select('id,amount_usd,network,txid,days,status,note,created_at')
      .eq('user_id', profile.id).order('created_at', { ascending: false }).limit(5),
  ]);
  const ok = access?.ok;
  const wallets = (plan?.wallets || []).filter((w) => w.address);
  const pendingPay = (payments || []).some((p) => p.status === 'pending');
  const err = ERRORS[searchParams?.e] || ACT_ERRORS[searchParams?.e];

  return (
    <>
      <TopBar profile={profile} />
      <main className="wrap grid" style={{ maxWidth: 620 }}>
        <h1>تنبيهات البيفوت 🔔</h1>
        <div className="muted" style={{ lineHeight: 1.8 }}>
          إشعار على موبايلك كل ما يوصل السعر لمستوى دعم أو مقاومة يومي (S1–S3، البيفوت، R1–R3)، نزولاً أو صعوداً،
          على 57 أداة: عملات، ذهب ونفط، مؤشرات، كريبتو وأسهم. التنبيهات معلومات عن السعر بس، مش توصيات شراء أو بيع.
        </div>
        {err && <div className="err">{err}</div>}
        {searchParams?.ok === 'paid' && (
          <div className="card hl"><b>وصلنا رقم العملية ✅</b>
            <div className="muted" style={{ marginTop: 6, lineHeight: 1.8 }}>منتأكد من التحويل على البلوكتشين ومنفعّل اشتراكك. عادة خلال ساعات العمل بنفس اليوم.</div>
          </div>
        )}

        {ok && (
          <div className="card hl grid">
            <div>
              <b style={{ fontSize: 17 }}>{access.reason === 'trial' ? 'تجربتك المجانية فعّالة ✅' : 'اشتراكك فعّال ✅'}</b>
              <div className="muted" style={{ marginTop: 4 }}>
                {access.reason === 'trial' && <>باقي <b>{hoursLeft(access.until)}</b> من التجربة المجانية (48 ساعة).</>}
                {access.reason === 'ib' && 'مجاناً لعملاء وكالة موقع توصيات.'}
                {access.reason === 'staff' && 'حساب فريق العمل.'}
                {access.reason === 'paid' && <>اشتراك مدفوع لغاية <span className="ltr">{day(access.until)}</span>.</>}
              </div>
            </div>
            <form action={openAlerts}><button className="btn green" style={{ width: '100%' }}>افتح تطبيق التنبيهات</button></form>
            <div className="note" style={{ lineHeight: 1.8 }}>
              بعد ما يفتح: الإعدادات ← <b>تفعيل الإشعارات</b> ← اسمح ← تنبيه تجريبي.
              على الآيفون: افتحه بـ Safari ← مشاركة ← «إضافة إلى الشاشة الرئيسية»، وبعدين افتحه من الأيقونة وفعّل الإشعارات.
            </div>
          </div>
        )}
        {!ok && access?.reason === 'trial_over' && (
          <div className="card"><b>انتهت التجربة المجانية (48 ساعة)</b>
            <div className="muted" style={{ marginTop: 4, lineHeight: 1.8 }}>التنبيهات مجانية لعملاء وكالة موقع توصيات. فعّل حسابك من تحت، أو اشترك.</div></div>
        )}
        {!ok && access?.reason === 'expired' && (
          <div className="card"><b>انتهى اشتراكك</b> <span className="muted">بتاريخ <span className="ltr">{day(access.until)}</span>. جدّده من تحت، أو فعّل حسابك كعميل وكالة.</span></div>
        )}

        {!profile.ib_verified && (!ok || access.reason === 'trial') && (
          <>
            <h2>{ok ? 'خلّيها مجانية بعد التجربة' : 'مجاناً لعملائنا'}</h2>
            <div className="muted" style={{ lineHeight: 1.8 }}>
              التنبيهات وغرف التوصيات مجانية لكل حدا عنده حساب تداول تحت وكالة موقع توصيات.
              ما عندك؟ اختار «ما عندي حساب تحت وكالتكم» واكتب رقم واتساب، وفريقنا بيساعدك تفتح أو تنقل حسابك.
            </div>
            <ActivationBox profile={profile} user={user} back="/alerts" />
          </>
        )}

        {!ok && (
          <>
            <h2>أو اشتراك مدفوع</h2>
            <div className="card grid">
              <div className="row" style={{ justifyContent: 'space-between' }}>
                <b style={{ fontSize: 20 }} className="ltr">${plan?.price_usd ?? '—'}</b>
                <span className="muted">لمدة {plan?.days ?? 30} يوم · الدفع بالكريبتو</span>
              </div>
              {wallets.length === 0 ? (
                <a className="btn" href={wa('مرحبا، بدي اشترك بتطبيق تنبيهات البيفوت. إيميلي: ' + (user?.email || ''))} target="_blank" rel="noopener">راسلنا على واتساب للدفع</a>
              ) : (
                <>
                  <ol style={{ margin: 0, paddingInlineStart: 20, lineHeight: 1.9, color: 'var(--soft)', fontSize: 14 }}>
                    <li>حوّل <b className="ltr">{plan.price_usd} USDT</b> بالضبط على العنوان تحت، <b>على نفس الشبكة المكتوبة</b>. التحويل على شبكة غلط بيضيع.</li>
                    <li>انسخ رقم العملية (TXID / Hash) من محفظتك وحطّه هون.</li>
                    <li>منتأكد منه على البلوكتشين ومنفعّل اشتراكك.</li>
                  </ol>
                  {wallets.map((w) => (
                    <div key={w.network} className="note grid" style={{ gap: 6 }}>
                      <b>{w.network}</b>
                      <div className="row" style={{ justifyContent: 'space-between', flexWrap: 'nowrap' }}>
                        <span className="ltr" style={{ wordBreak: 'break-all', fontFamily: 'monospace', fontSize: 13 }}>{w.address}</span>
                        <CopyButton text={w.address} />
                      </div>
                    </div>
                  ))}
                  <form action={submitPayment} className="grid">
                    <label>الشبكة اللي حوّلت عليها
                      <select name="network" defaultValue={wallets[0].network}>{wallets.map((w) => <option key={w.network}>{w.network}</option>)}</select>
                    </label>
                    <label>رقم العملية (TXID)
                      <input name="txid" dir="ltr" required minLength={20} maxLength={120} pattern="[A-Za-z0-9]{20,120}" title="انسخ رقم العملية كامل" autoComplete="off" />
                    </label>
                    <button className="btn" disabled={pendingPay} style={pendingPay ? { opacity: 0.5 } : undefined}>{pendingPay ? 'دفعتك قيد المراجعة' : 'أرسل رقم العملية'}</button>
                  </form>
                  <div className="muted">بدك تدفع بعملة أو شبكة ثانية؟ <a href={wa('مرحبا، بدي اشترك بتطبيق التنبيهات بالكريبتو. إيميلي: ' + (user?.email || ''))} target="_blank" rel="noopener">راسلنا على واتساب</a>.</div>
                </>
              )}
            </div>
          </>
        )}

        {payments?.length > 0 && (
          <>
            <h2>مدفوعاتك</h2>
            <div className="card" style={{ overflowX: 'auto' }}>
              <table>
                <thead><tr><th>التاريخ</th><th>المبلغ</th><th>الشبكة</th><th>TXID</th><th>الحالة</th></tr></thead>
                <tbody>{payments.map((p) => (
                  <tr key={p.id}>
                    <td className="ltr">{day(p.created_at)}</td>
                    <td className="ltr">${p.amount_usd}</td>
                    <td>{p.network}</td>
                    <td className="ltr" style={{ fontFamily: 'monospace' }}>{p.txid.slice(0, 8)}…{p.txid.slice(-6)}</td>
                    <td className={p.status === 'approved' ? 'ok' : p.status === 'rejected' ? 'bad' : 'muted'}>
                      {STATUS_AR[p.status]}{p.status === 'rejected' && p.note ? ` — ${p.note}` : ''}
                    </td>
                  </tr>))}
                </tbody>
              </table>
            </div>
          </>
        )}
      </main>
    </>
  );
}
