import TopBar from '../TopBar';
import { currentUser } from '@/lib/supabase-server';
import { fmt, STATE_AR } from '@/lib/format';
import { approveSuggestion, rejectSuggestion, verifyClient } from './actions';

export const dynamic = 'force-dynamic';

const RULE_AR = { daily_trend: 'الاتجاه اليومي', h1_trend: 'اتجاه الساعة', entry_at_pivot: 'الدخول على البيفوت', stop_atr: 'حجم الستوب', stop_size: 'حجم الستوب', tp1_distance: 'مسافة الهدف 1', levels_order: 'ترتيب المستويات', news: 'الأخبار', analyst_note: 'ملاحظة المحلل' };

export default async function Admin() {
  const { sb, profile } = await currentUser();
  if (!profile || !['analyst', 'manager', 'admin'].includes(profile.role)) {
    return (<><TopBar profile={profile} /><main className="wrap"><div className="card">هالصفحة للفريق بس.</div></main></>);
  }
  const canDecide = ['manager', 'admin'].includes(profile.role);
  const [{ data: pending }, { data: queue }, { data: recent }, { data: log }] = await Promise.all([
    sb.from('suggestions').select('*').eq('status', 'pending').order('created_at', { ascending: false }),
    sb.from('profiles').select('id,display_name,broker,broker_account,activation_requested_at').eq('ib_verified', false).not('activation_requested_at', 'is', null).order('activation_requested_at'),
    sb.from('signals').select('*').order('published_at', { ascending: false }).limit(20),
    sb.from('engine_log').select('*').order('t', { ascending: false }).limit(5),
  ]);
  const live = Object.fromEntries(await Promise.all((pending || []).map(async (s) => {
    const { data } = await sb.rpc('suggestion_live_check', { p_id: s.id });
    return [s.id, data || { ok: true }];
  })));

  return (
    <>
      <TopBar profile={profile} />
      <main className="wrap grid">
        <div className="row" style={{ justifyContent: 'space-between' }}>
          <h1>الباك أوفيس</h1>
          <a className="btn" href="/admin/new">+ توصية من المحلل</a>
        </div>

        {log && log.length > 0 && (
          <div className="note">
            <b>السيستم اليوم:</b>{' '}
            {log[0].msg === 'suggestion created' ? 'طلّع اقتراح، شوفه تحت.'
              : log[0].msg.includes('H1') ? 'ما في صفقة: اتجاه الساعة عكس الاتجاه اليومي.'
              : log[0].msg.includes('beyond') ? 'ما في صفقة: السوق فتح بعد نقطة البيفوت.'
              : log[0].msg.includes('history') ? 'ما في بيانات أسعار كافية لسا (جسر الأسعار).'
              : log[0].msg}
            <span className="muted ltr"> · {new Date(log[0].t).toISOString().slice(0, 16).replace('T', ' ')} GMT</span>
          </div>
        )}

        <h2>اقتراحات بانتظار الموافقة ({pending?.length || 0})</h2>
        {(!pending || pending.length === 0) && <div className="card muted">ما في اقتراحات جديدة.</div>}
        {pending?.map((s) => (
          <div key={s.id} className="card grid">
            <div className="row" style={{ justifyContent: 'space-between' }}>
              <div className="row">
                <b>{s.symbol}</b>
                <span className={`badge ${s.side === 'BUY' ? 'buy' : 'sell'}`}>{s.side === 'BUY' ? 'شراء' : 'بيع'}</span>
                <span className="muted">{s.source === 'engine' ? 'من السيستم' : 'من المحلل'}</span>
              </div>
              <b className={s.check_passed ? 'ok' : 'bad'}>{s.check_passed ? 'عدّت الفحص ✓' : 'ما عدّت الفحص ✗'}</b>
            </div>
            <div className="kv">
              <div><span className="muted">الدخول</span><b>{fmt(s.entry)}</b></div>
              <div><span className="muted">الستوب</span><b className="bad">{fmt(s.stop_loss)}</b></div>
              <div><span className="muted">الهدف 1</span><b className="ok">{fmt(s.tp1)}</b></div>
              <div><span className="muted">الهدف 2</span><b className="ok">{fmt(s.tp2)}</b></div>
            </div>
            {s.hist_sample && (
              <div className="note">
                تاريخياً، الإعداد هاد: <b>{fmt(s.hist_win_rate, 0)}%</b> نجاح، متوسط <b className="ltr">{s.hist_avg_r > 0 ? '+' : ''}{fmt(s.hist_avg_r, 2)}R</b> على <b>{s.hist_sample}</b> صفقة.
                المخاطرة <span className="ltr">${fmt(s.risk_usd_001, 1)}</span> لكل 0.01 لوت.
              </div>
            )}
            <table><tbody>
              {(s.check_reasons || []).map((r, i) => (
                <tr key={i}><td className={r.ok ? 'ok' : 'bad'}>{r.ok ? '✓' : '✗'}</td><td>{RULE_AR[r.rule] || r.rule}</td><td className="muted">{r.detail}</td></tr>
              ))}
            </tbody></table>
            {live[s.id] && !live[s.id].ok && (
              <div className="err">ما بينفع تنشرها هلق: {live[s.id].reason}</div>
            )}
            {live[s.id]?.ok && live[s.id].price != null && (
              <div className="muted">السعر الآن <b className="ltr">{fmt(live[s.id].price)}</b> · الدخول لسا متاح ✓</div>
            )}
            {canDecide ? (
              <div className="grid g2">
                <form action={approveSuggestion} className="grid">
                  <input type="hidden" name="id" value={s.id} />
                  <div className="row">
                    <label className="row" style={{ flexDirection: 'row' }}><input type="checkbox" name="rooms" value="1" defaultChecked style={{ height: 18 }} /> غرفة 1</label>
                    <label className="row" style={{ flexDirection: 'row' }}><input type="checkbox" name="rooms" value="2" defaultChecked style={{ height: 18 }} /> غرفة 2</label>
                  </div>
                  <button className="btn green" disabled={live[s.id] && !live[s.id].ok} style={live[s.id] && !live[s.id].ok ? { opacity: 0.4 } : undefined}>وافق وانشر</button>
                </form>
                <form action={rejectSuggestion} className="grid">
                  <input type="hidden" name="id" value={s.id} />
                  <input name="note" placeholder="سبب الرفض (اختياري)" />
                  <button className="btn red">ارفض</button>
                </form>
              </div>
            ) : <div className="muted">الموافقة لمدير الحساب.</div>}
          </div>
        ))}

        {canDecide && (
          <>
            <h2>طلبات تفعيل العملاء ({queue?.length || 0})</h2>
            {(!queue || queue.length === 0) && <div className="card muted">ما في طلبات.</div>}
            {queue?.map((c) => (
              <form key={c.id} action={verifyClient} className="card row" style={{ justifyContent: 'space-between' }}>
                <input type="hidden" name="id" value={c.id} />
                <div><b>{c.display_name}</b><div className="muted">{c.broker} · <span className="ltr">{c.broker_account}</span></div></div>
                <div className="row">
                  <input name="balance" type="number" placeholder="الرصيد $" required style={{ width: 130 }} dir="ltr" />
                  <button className="btn">فعّل</button>
                </div>
              </form>
            ))}
          </>
        )}

        <h2>آخر التوصيات المنشورة</h2>
        <div className="card" style={{ overflowX: 'auto' }}>
          <table>
            <thead><tr><th>التاريخ</th><th>الأصل</th><th>الاتجاه</th><th>الدخول</th><th>الحالة</th><th>R (هدف 1)</th><th>R (تقسيم)</th></tr></thead>
            <tbody>
              {recent?.map((s) => (
                <tr key={s.id}>
                  <td className="ltr">{new Date(s.published_at).toISOString().slice(0, 16).replace('T', ' ')}</td>
                  <td>{s.symbol}</td><td>{s.side === 'BUY' ? 'شراء' : 'بيع'}</td><td className="ltr">{fmt(s.entry)}</td>
                  <td>{STATE_AR[s.state] || s.state}</td>
                  <td className="ltr">{s.result_r_tp1only ?? '—'}</td><td className="ltr">{s.result_r_partial ?? '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </main>
    </>
  );
}
