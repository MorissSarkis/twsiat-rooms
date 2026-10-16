import Link from 'next/link';
import TopBar from '../TopBar';
import { currentUser } from '@/lib/supabase-server';
import { fmt, ORDER_AR, CSTATE_AR, when } from '@/lib/format';
import { UsernameForm, PostForm, CopyButton } from './forms';

export const dynamic = 'force-dynamic';
const RANK_AFTER = 20;

function Record({ st }) {
  if (!st || st.trades === 0) return <span className="muted">لسا ما في صفقات مسكّرة</span>;
  return (
    <span className="muted">
      {st.trades} صفقة · نجاح {fmt(st.win_rate, 0)}% · <span className={Number(st.total_r) >= 0 ? 'ok' : 'bad'}>{Number(st.total_r) >= 0 ? '+' : ''}{fmt(st.total_r, 1)}R</span>
      {st.trades < RANK_AFTER && <> · قيد التقييم ({st.trades}/{RANK_AFTER})</>}
    </span>
  );
}

function Idea({ t, st, sym }) {
  const d = sym?.digits ?? 2;
  const buy = t.side === 'BUY';
  const copy = `${t.symbol} ${t.side} ${t.order_type === 'MARKET' ? 'MARKET' : t.order_type.replace('_', ' ')} @ ${t.entry} | SL ${t.stop_loss} | TP ${t.take_profit}`;
  const live = t.state === 'waiting' || t.state === 'open';
  return (
    <div className="card grid">
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <div className="row">
          <Link href={`/community?u=${t.username}`}><b className="ltr">@{t.username}</b></Link>
          <Record st={st} />
        </div>
        <span className="muted ltr">{when(t.posted_at)}</span>
      </div>
      <div className="row">
        <b>{sym?.name || t.symbol}</b> <span className="muted ltr">{t.symbol}</span>
        <span className={`badge ${buy ? 'buy' : 'sell'}`}>{buy ? 'شراء' : 'بيع'}</span>
        <span className="muted ltr">{ORDER_AR[t.order_type]}</span>
      </div>
      <div className="kv" style={{ gridTemplateColumns: 'repeat(3,minmax(0,1fr))' }}>
        <div><span className="muted">الدخول</span><b>{fmt(t.entry, d)}</b></div>
        <div><span className="muted">وقف الخسارة</span><b className="bad">{fmt(t.stop_loss, d)}</b></div>
        <div><span className="muted">الهدف</span><b className="ok">{fmt(t.take_profit, d)}</b></div>
      </div>
      {t.note && <div className="note">{t.note}</div>}
      <div className="row" style={{ justifyContent: 'space-between' }}>
        <span className={t.state === 'tp' ? 'ok' : t.state === 'sl' ? 'bad' : 'muted'}>
          {CSTATE_AR[t.state] || t.state}
          {t.result_r != null && <> · <span className="ltr">{Number(t.result_r) >= 0 ? '+' : ''}{fmt(t.result_r, 2)}R</span></>}
        </span>
        {live && !t.mine && <CopyButton text={copy} />}
      </div>
    </div>
  );
}

export default async function Community({ searchParams }) {
  const { sb, profile } = await currentUser();
  if (!profile) return null;
  const tab = searchParams?.u ? 'user' : searchParams?.tab === 'top' ? 'top' : 'feed';

  const [{ data: stats }, { data: symbols }, { data: feed }] = await Promise.all([
    sb.rpc('community_stats'),
    sb.rpc('list_symbols'),
    tab === 'top' ? Promise.resolve({ data: [] }) : sb.rpc('community_feed', { p_limit: 60, p_username: searchParams?.u || null }),
  ]);
  const symBy = Object.fromEntries((symbols || []).map((x) => [x.code, x]));
  const byUser = Object.fromEntries((stats || []).map((s) => [s.username, s]));
  const ranked = (stats || []).filter((s) => s.trades >= RANK_AFTER).sort((a, b) => Number(b.total_r) - Number(a.total_r));
  const rising = (stats || []).filter((s) => s.trades < RANK_AFTER && s.trades > 0).sort((a, b) => b.trades - a.trades);

  return (
    <>
      <TopBar profile={profile} />
      <main className="wrap grid">
        <h1>غرفة المجتمع</h1>
        <div className="muted" style={{ lineHeight: 1.8 }}>
          أفكار صفقات من أعضاء موقع توصيات. كل فكرة بتنسجّل بسعر ووقت السيرفر وبتنتابع تلقائياً على الأسعار الحقيقية،
          فالأداء اللي بتشوفه حقيقي وما حدا بيقدر يعدّل عليه. الترتيب بيبلّش بعد {RANK_AFTER} صفقة مسكّرة.
        </div>

        {!profile.username ? <UsernameForm />
          : !profile.ib_verified ? <div className="card muted">النشر متاح للحسابات المفعّلة. فعّل حسابك من <Link href="/rooms">غرف التوصيات</Link>. فيك تتصفح الأفكار من هلق.</div>
          : <PostForm symbols={symbols || []} />}

        <div className="tabs">
          <Link href="/community" className={tab === 'feed' ? 'on' : ''}>آخر الأفكار</Link>
          <Link href="/community?tab=top" className={tab === 'top' ? 'on' : ''}>الترتيب</Link>
          {profile.username && <Link href={`/community?u=${profile.username}`} className={tab === 'user' && searchParams?.u === profile.username ? 'on' : ''}>أفكاري</Link>}
          {tab === 'user' && searchParams?.u !== profile.username && <span className="tabs"><a className="on ltr">@{searchParams.u}</a></span>}
        </div>

        {tab === 'top' ? (
          <div className="grid">
            <div className="card grid">
              <b>الترتيب (من {RANK_AFTER} صفقة وفوق)</b>
              {ranked.length === 0 ? <div className="muted">ما حدا وصل {RANK_AFTER} صفقة مسكّرة لهلأ.</div> : (
                <table>
                  <thead><tr><th>#</th><th>العضو</th><th>صفقات</th><th>نجاح</th><th>مجموع R</th><th>متوسط R</th></tr></thead>
                  <tbody>{ranked.map((s, i) => (
                    <tr key={s.username}>
                      <td>{i + 1}</td>
                      <td><Link href={`/community?u=${s.username}`} className="ltr">@{s.username}</Link></td>
                      <td>{s.trades}</td><td>{fmt(s.win_rate, 0)}%</td>
                      <td className={Number(s.total_r) >= 0 ? 'ok ltr' : 'bad ltr'}>{fmt(s.total_r, 1)}</td>
                      <td className="ltr">{fmt(s.avg_r, 2)}</td>
                    </tr>))}
                  </tbody>
                </table>
              )}
            </div>
            {rising.length > 0 && (
              <div className="card grid">
                <b>قيد التقييم</b>
                {rising.map((s) => (
                  <div key={s.username} className="row" style={{ justifyContent: 'space-between' }}>
                    <Link href={`/community?u=${s.username}`} className="ltr">@{s.username}</Link>
                    <Record st={s} />
                  </div>
                ))}
              </div>
            )}
            <div className="note">الـ R = الربح أو الخسارة مقارنة بالمخاطرة. +2R يعني ربح ضعف المسافة للستوب، و −1R يعني ضرب الستوب.</div>
          </div>
        ) : (
          <div className="grid">
            {(!feed || feed.length === 0) && <div className="card muted">ما في أفكار لهلأ. كون أول واحد بينشر.</div>}
            {feed?.map((t) => <Idea key={t.id} t={t} st={byUser[t.username]} sym={symBy[t.symbol]} />)}
          </div>
        )}

        <div className="note">أفكار الأعضاء مش توصيات من موقع توصيات. النسخ يدوي وعلى مسؤوليتك، وانتبه لحجم اللوت حسب حسابك.</div>
      </main>
    </>
  );
}
