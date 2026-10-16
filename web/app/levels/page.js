import TopBar from '../TopBar';
import { currentUser } from '@/lib/supabase-server';
import Link from 'next/link';
import { fmt, when } from '@/lib/format';

export const dynamic = 'force-dynamic';

const KIND = {
  R3: 'res', R2: 'res', R1: 'res', P: 'piv', S1: 'sup', S2: 'sup', S3: 'sup',
  'قمة أمس': 'prev', 'قاع أمس': 'prev',
};

function Ladder({ L, d }) {
  const rows = [
    ...Object.entries(L.pivot).map(([k, v]) => ({ k, v: Number(v) })),
    { k: 'قمة أمس', v: Number(L.prev.high) },
    { k: 'قاع أمس', v: Number(L.prev.low) },
  ].sort((a, b) => b.v - a.v);
  const price = Number(L.price);
  const at = rows.findIndex((r) => r.v < price);
  const idx = at === -1 ? rows.length : at;
  const list = [...rows.slice(0, idx), { k: 'السعر الآن', v: price, now: true }, ...rows.slice(idx)];
  return (
    <div className="ladder">
      {list.map((r) => (
        <div key={r.k} className={`lv ${r.now ? 'now' : KIND[r.k] || ''}`}>
          <span>{r.k}</span>
          <b className="ltr">{fmt(r.v, d)}</b>
          <span className="muted ltr">{r.now ? '' : `${r.v > price ? '+' : ''}${fmt(r.v - price, Math.max(d - 1, 0))}`}</span>
        </div>
      ))}
    </div>
  );
}

const TREND = (t) => (t === 'UP' ? <span className="ok">صاعد ▲</span> : t === 'DOWN' ? <span className="bad">هابط ▼</span> : <span className="muted">—</span>);

export default async function Levels({ searchParams }) {
  const { sb, profile } = await currentUser();
  if (!profile) return null;
  const { data: symbols } = await sb.rpc('list_symbols');
  const list = symbols || [];
  const s = list.find((x) => x.code === searchParams?.s) || list[0];
  const { data: L } = s ? await sb.rpc('market_levels', { p_symbol: s.code }) : { data: null };
  const d = s?.digits ?? 2;
  const groups = [...new Set(list.map((x) => x.group || ''))];

  return (
    <>
      <TopBar profile={profile} />
      <main className="wrap grid">
        <h1>مستويات اليوم</h1>
        <div className="muted" style={{ lineHeight: 1.8 }}>
          نقاط البيفوت والدعم والمقاومة لليوم محسوبة من شمعة أمس اليومية، وبتتحدث تلقائياً كل يوم مع افتتاح السوق.
          الاتجاه هو نفس الفلتر اللي بيستعمله نظام التوصيات.
        </div>

        <div className="grid" style={{ gap: 8 }}>
          {groups.map((g) => (
            <div key={g} className="tabs" style={{ alignItems: 'center' }}>
              {g && <span className="muted" style={{ minWidth: 56 }}>{g}</span>}
              {list.filter((x) => (x.group || '') === g).map((x) => (
                <Link key={x.code} href={`/levels?s=${x.code}`} className={x.code === s?.code ? 'on' : ''}>{x.name}</Link>
              ))}
            </div>
          ))}
        </div>

        {!s || !L ? (
          <div className="card muted">ما في أسعار لهالأصل لهلأ.</div>
        ) : (
          <section className="grid">
            <div className="card hl row" style={{ justifyContent: 'space-between' }}>
              <div>
                <b style={{ fontSize: 18 }}>{s.name}</b> <span className="muted ltr">{s.code}</span>
                <div className="muted">آخر سعر: <b className="ltr" style={{ color: 'var(--text)' }}>{fmt(L.price, d)}</b> · <span className="ltr">{when(L.price_t)}</span></div>
              </div>
              <div className="grid" style={{ gap: 4, textAlign: 'left' }}>
                <div className="muted">الاتجاه اليومي: {TREND(L.daily_trend)}</div>
                <div className="muted">اتجاه الساعة: {TREND(L.h1_trend)}</div>
              </div>
            </div>

            <div className="grid g2">
              <div className="card grid">
                <b>البيفوت والدعوم والمقاومات</b>
                <Ladder L={L} d={d} />
              </div>
              <div className="grid">
                <div className="card grid">
                  <b>فيبوناتشي (مدى أمس، باتجاه الترند)</b>
                  <table><tbody>
                    {Object.entries(L.fib).map(([k, v]) => (
                      <tr key={k}><td className="ltr">{k}%</td><td className="ltr"><b>{fmt(v, d)}</b></td></tr>
                    ))}
                  </tbody></table>
                  <div className="muted">مستويات تصحيح محتملة بعكس الترند قبل ما يكمّل.</div>
                </div>
                <div className="card grid">
                  <b>أرقام مفيدة</b>
                  <table><tbody>
                    <tr><td>متوسط الحركة اليومية (ATR 14)</td><td className="ltr"><b>{fmt(L.atr, d)}</b></td></tr>
                    <tr><td>متوسط 50 يوم</td><td className="ltr"><b>{L.sma50 == null ? '— (بيانات أقل من 50 يوم)' : fmt(L.sma50, d)}</b></td></tr>
                    <tr><td>قمة / قاع / إغلاق أمس</td><td className="ltr">{fmt(L.prev.high, d)} / {fmt(L.prev.low, d)} / {fmt(L.prev.close, d)}</td></tr>
                  </tbody></table>
                  <div className="muted">ستوب أصغر من ربع الـ ATR غالباً بيضرب من الضجيج؛ وأكبر من الـ ATR كله كبير على الحسابات الصغيرة.</div>
                </div>
              </div>
            </div>
          </section>
        )}
        <div className="note">المستويات أداة مساعدة مش توصية. القرار والمخاطرة على المتداول.</div>
      </main>
    </>
  );
}
