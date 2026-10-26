import TopBar from '../../TopBar';
import { currentUser } from '@/lib/supabase-server';
import { when } from '@/lib/format';
import { grantAlerts } from '../actions';

export const dynamic = 'force-dynamic';

const FILTERS = [['', 'الكل'], ['pending', 'طلبات تفعيل'], ['transfer', 'بدهم نقل حساب'], ['ib', 'عملاء الوكالة'], ['trial', 'تجربة 48 ساعة'], ['paid', 'اشتراك مدفوع'], ['none', 'مسجّلين بس'], ['staff', 'الفريق']];
const PER_PAGE = 50;

function Status({ m }) {
  if (['analyst', 'manager', 'admin'].includes(m.role)) return <span className="badge" style={{ background: '#8FA3BF' }}>فريق</span>;
  if (m.ib_verified) return <span className="badge buy">عميل وكالة</span>;
  if (m.activation_rejected_at) return <span className="badge sell">طلب مرفوض</span>;
  if (m.activation_requested_at && m.has_ib_account === false) return <span className="badge" style={{ background: 'var(--gold)' }}>بدّه نقل حساب</span>;
  if (m.activation_requested_at) return <span className="badge" style={{ background: 'var(--gold)' }}>طلب تفعيل</span>;
  return <span className="badge" style={{ background: '#3A4658', color: 'var(--soft)' }}>مسجّل</span>;
}

export default async function Members({ searchParams }) {
  const { sb, profile } = await currentUser();
  if (!profile || !['manager', 'admin'].includes(profile.role)) {
    return (<><TopBar profile={profile} /><main className="wrap"><div className="card">هالصفحة للمدير بس.</div></main></>);
  }
  const q = String(searchParams?.q || '').slice(0, 80);
  const status = FILTERS.some(([k]) => k === searchParams?.s) ? searchParams.s : '';
  const page = Math.max(0, Number(searchParams?.p) || 0);
  const { data: rows, error } = await sb.rpc('admin_members', { p_search: q || null, p_status: status || null, p_limit: PER_PAGE, p_offset: page * PER_PAGE });
  const total = rows?.[0]?.total || 0;
  const link = (o) => {
    const u = new URLSearchParams({ ...(q && { q }), ...(status && { s: status }), ...o });
    for (const [k, v] of [...u]) if (v === '' || v === '0') u.delete(k);
    return `/admin/members${u.toString() ? '?' + u : ''}`;
  };

  return (
    <>
      <TopBar profile={profile} />
      <main className="wrap grid">
        <div className="row" style={{ justifyContent: 'space-between' }}>
          <h1>الأعضاء <span className="muted" style={{ fontSize: 15 }}>({total})</span></h1>
          <div className="row">
            <a className="btn ghost" href={`/admin/members/export${q || status ? '?' + new URLSearchParams({ ...(q && { q }), ...(status && { s: status }) }) : ''}`}>تنزيل Excel (CSV)</a>
            <a className="btn ghost" href="/admin">رجوع للباك أوفيس</a>
          </div>
        </div>

        <form className="row" action="/admin/members">
          <input name="q" defaultValue={q} placeholder="ابحث بالاسم، الإيميل أو رقم الحساب" style={{ flex: 1, minWidth: 200 }} />
          {status && <input type="hidden" name="s" value={status} />}
          <button className="btn">بحث</button>
        </form>
        <div className="row">
          {FILTERS.map(([k, label]) => (
            <a key={k} href={link({ s: k, p: '' })} className={`btn ${status === k ? '' : 'ghost'}`} style={{ minHeight: 32, padding: '0 12px' }}>{label}</a>
          ))}
        </div>

        {error && <div className="err">ما قدرنا نجيب القائمة. تأكد إنك شغّلت db/022_admin_members.sql.</div>}
        {rows?.length === 0 && <div className="card muted">ما في أعضاء بهالبحث.</div>}

        {rows?.map((m) => {
          const paid = m.alerts_paid_until && new Date(m.alerts_paid_until) > new Date();
          return (
            <div key={m.id} className="card grid" style={{ gap: 8 }}>
              <div className="row" style={{ justifyContent: 'space-between' }}>
                <div className="row"><b>{m.name || '—'}</b>{m.username && <span className="muted ltr">@{m.username}</span>}<Status m={m} /></div>
                <span className="muted">سجّل <span className="ltr">{when(m.signed_up)}</span></span>
              </div>
              <div className="row" style={{ justifyContent: 'space-between' }}>
                <span className="row" style={{ gap: 10 }}>
                  <a className="ltr" href={`mailto:${m.email}`} style={{ color: 'var(--text)' }}>{m.email}</a>
                  {m.phone && <a className="ltr" href={`https://wa.me/${m.phone.replace(/[^0-9]/g, '')}`} target="_blank" rel="noopener" style={{ color: 'var(--buy)' }}>{m.phone}</a>}
                </span>
                <span className="muted">
                  {m.provider === 'google' ? 'Google' : 'إيميل'}{!m.email_confirmed && m.provider !== 'google' ? ' (ما أكّد الإيميل)' : ''}
                  {' · '}آخر دخول <span className="ltr">{when(m.last_login)}</span>
                </span>
              </div>
              {(m.broker || m.broker_account) && (
                <div className="muted">
                  {m.broker} · <span className="ltr">{m.broker_account}</span>
                  {m.balance_usd != null && <> · الرصيد <span className="ltr">${m.balance_usd}</span></>}
                  {m.room && <> · غرفة {m.room}</>}
                  {m.verified_at && <> · فعّله {m.verified_by_name || 'الإدارة'} <span className="ltr">{when(m.verified_at)}</span></>}
                </div>
              )}
              {m.activation_rejected_at && <div className="bad" style={{ fontSize: 13 }}>رُفض الطلب <span className="ltr">{when(m.activation_rejected_at)}</span>{m.activation_note ? ` — ${m.activation_note}` : ''}</div>}
              <div className="row" style={{ justifyContent: 'space-between' }}>
                <span className="muted">
                  التنبيهات: {m.alerts_reason === 'ib' ? 'مجاني (وكالة)' : m.alerts_reason === 'staff' ? 'فريق'
                    : paid ? <>مدفوع لغاية <span className="ltr">{when(m.alerts_paid_until)}</span></>
                    : m.alerts_reason === 'trial' ? <>تجربة لغاية <span className="ltr">{when(m.alerts_trial_until)}</span></>
                    : m.alerts_paid_until ? <span className="bad">انتهى <span className="ltr">{when(m.alerts_paid_until)}</span></span> : 'لا'}
                </span>
                {m.alerts_reason !== 'ib' && m.alerts_reason !== 'staff' && (
                  <div className="row" style={{ flexWrap: 'nowrap' }}>
                    <form action={grantAlerts}><input type="hidden" name="id" value={m.id} /><input type="hidden" name="days" value="30" /><button className="btn ghost" style={{ minHeight: 32, padding: '0 10px' }}>تنبيهات +30 يوم</button></form>
                    {paid && <form action={grantAlerts}><input type="hidden" name="id" value={m.id} /><input type="hidden" name="days" value="0" /><button className="btn red" style={{ minHeight: 32, padding: '0 10px' }}>إيقاف</button></form>}
                  </div>
                )}
              </div>
            </div>
          );
        })}

        {total > PER_PAGE && (
          <div className="row" style={{ justifyContent: 'space-between' }}>
            {page > 0 ? <a className="btn ghost" href={link({ p: String(page - 1) })}>السابق</a> : <span />}
            <span className="muted">صفحة {page + 1} من {Math.ceil(total / PER_PAGE)}</span>
            {(page + 1) * PER_PAGE < total ? <a className="btn ghost" href={link({ p: String(page + 1) })}>التالي</a> : <span />}
          </div>
        )}
      </main>
    </>
  );
}
