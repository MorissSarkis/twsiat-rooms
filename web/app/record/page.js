import Link from 'next/link';
import TopBar from '../TopBar';
import { currentUser } from '@/lib/supabase-server';
import { fmt, symName, STATE_AR, when, px } from '@/lib/format';

export const dynamic = 'force-dynamic';
export const metadata = { title: 'سجل الأداء — موقع توصيات', description: 'كل توصية نشرناها ونتيجتها الحقيقية، بدون حذف ولا تعديل.' };

const R = (v) => (v == null ? '—' : `${Number(v) >= 0 ? '+' : ''}${fmt(v, 2)}R`);

export default async function Record() {
  const { sb, profile } = await currentUser();
  const { data } = await sb.rpc('track_record', { p_limit: 200 });
  const summary = data?.summary || [];
  const trades = data?.trades || [];
  const all = summary.reduce((a, s) => ({
    trades: a.trades + s.trades, wins: a.wins + s.wins,
    p: a.p + Number(s.total_r_partial), t: a.t + Number(s.total_r_tp1only),
  }), { trades: 0, wins: 0, p: 0, t: 0 });

  return (
    <>
      <TopBar profile={profile} />
      <main className="wrap grid">
        <h1>سجل الأداء</h1>
        <div className="muted" style={{ lineHeight: 1.8 }}>
          كل توصية بننشرها بتنتابع تلقائياً على أسعار السوق الحقيقية لحد ما تسكّر، وبتنعرض هون بنتيجتها، ربح أو خسارة،
          بدون حذف ولا تعديل. الـ R يعني الربح مقارنة بالمخاطرة: +1R ربح بقد مسافة الستوب، و −1R ضرب الستوب.
        </div>

        <div className="grid g2">
          <div className="card hl grid" style={{ gap: 6 }}>
            <div className="muted">كل الأدوات</div>
            <b style={{ fontSize: 22 }}>{all.trades} صفقة مسكّرة</b>
            <div>نسبة النجاح: <b>{all.trades ? `${fmt((100 * all.wins) / all.trades, 0)}%` : '—'}</b></div>
            <div>نص عند الهدف 1 والباقي للهدف 2: <b className={all.p >= 0 ? 'ok ltr' : 'bad ltr'}>{all.trades ? R(all.p) : '—'}</b></div>
            <div>الهدف 1 بس: <b className={all.t >= 0 ? 'ok ltr' : 'bad ltr'}>{all.trades ? R(all.t) : '—'}</b></div>
          </div>
          <div className="card grid" style={{ gap: 6 }}>
            <div>صفقات شغّالة هلق: <b>{data?.open_now ?? 0}</b></div>
            <div>أوامر معلّقة ما اتفعّلت وانلغت: <b>{data?.not_triggered ?? 0}</b></div>
            <div className="muted">تفاصيل الصفقات الشغّالة (الدخول والستوب والأهداف) داخل الغرف بس.</div>
            {!profile && <Link className="btn" href="/login">ادخل للغرف</Link>}
          </div>
        </div>

        {summary.length > 0 && (
          <div className="card">
            <table>
              <thead><tr><th>الأداة</th><th>صفقات</th><th>نجاح</th><th>نص/نص</th><th>الهدف 1 بس</th><th>من تاريخ</th></tr></thead>
              <tbody>{summary.map((s) => (
                <tr key={s.symbol}>
                  <td>{symName(s.symbol)}</td><td>{s.trades}</td><td>{fmt(s.win_rate, 0)}%</td>
                  <td className={Number(s.total_r_partial) >= 0 ? 'ok ltr' : 'bad ltr'}>{R(s.total_r_partial)}</td>
                  <td className={Number(s.total_r_tp1only) >= 0 ? 'ok ltr' : 'bad ltr'}>{R(s.total_r_tp1only)}</td>
                  <td className="ltr">{s.since ? new Date(s.since).toISOString().slice(0, 10) : '—'}</td>
                </tr>))}
              </tbody>
            </table>
          </div>
        )}

        <h2>كل الصفقات المسكّرة</h2>
        {trades.length === 0 ? <div className="card muted">لسا ما في صفقات مسكّرة.</div> : (
          <div className="card" style={{ overflowX: 'auto' }}>
            <table>
              <thead><tr><th>تاريخ النشر</th><th>الأداة</th><th>الاتجاه</th><th>الدخول</th><th>الستوب</th><th>الهدف 1</th><th>الهدف 2</th><th>النتيجة</th><th>نص/نص</th><th>الهدف 1 بس</th></tr></thead>
              <tbody>{trades.map((t) => (
                <tr key={t.id}>
                  <td className="ltr">{when(t.published_at)}</td>
                  <td>{symName(t.symbol)}</td>
                  <td><span className={`badge ${t.side === 'BUY' ? 'buy' : 'sell'}`}>{t.side === 'BUY' ? 'شراء' : 'بيع'}</span></td>
                  <td className="ltr">{px(t.symbol, t.entry)}</td><td className="ltr">{px(t.symbol, t.stop_loss)}</td>
                  <td className="ltr">{px(t.symbol, t.tp1)}</td><td className="ltr">{px(t.symbol, t.tp2)}</td>
                  <td>{STATE_AR[t.state] || t.state}</td>
                  <td className={Number(t.result_r_partial) >= 0 ? 'ok ltr' : 'bad ltr'}>{R(t.result_r_partial)}</td>
                  <td className={Number(t.result_r_tp1only) >= 0 ? 'ok ltr' : 'bad ltr'}>{R(t.result_r_tp1only)}</td>
                </tr>))}
              </tbody>
            </table>
          </div>
        )}
        <div className="note">الأداء السابق ما بيضمن نتائج مستقبلية. التداول فيه مخاطرة عالية بخسارة رأس المال.</div>
      </main>
    </>
  );
}
