import TopBar from '../TopBar';
import { currentUser } from '@/lib/supabase-server';
import { symName, fmt, STATE_AR, when, px } from '@/lib/format';
import { setRoom, approveSuggestion, rejectSuggestion, verifyClient, promoteCommunity, approvePayment, rejectPayment, grantAlerts, rejectActivation } from './actions';

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
    sb.from('profiles').select('id,display_name,broker,broker_account,activation_requested_at,phone,has_ib_account,reported_balance').eq('ib_verified', false).not('activation_requested_at', 'is', null).is('activation_rejected_at', null).order('activation_requested_at'),
    sb.from('signals').select('*').eq('shadow', false).order('published_at', { ascending: false }).limit(20),
    sb.from('engine_log').select('*').order('t', { ascending: false }).limit(20),
  ]);
  const { data: shadow } = await sb.rpc('shadow_stats');
  const { data: upgrades } = canDecide
    ? await sb.from('profiles').select('id,display_name,broker,broker_account,balance_usd,upgrade_balance,upgrade_requested_at,phone').not('upgrade_requested_at', 'is', null).order('upgrade_requested_at')
    : { data: [] };
  // pivot alerts: crypto payments waiting + current paid subscribers
  const [{ data: pays }, { data: subs }] = canDecide ? await Promise.all([
    sb.from('alerts_payments').select('*').eq('status', 'pending').order('created_at'),
    sb.from('profiles').select('id,display_name,username,alerts_paid_until').not('alerts_paid_until', 'is', null)
      .gt('alerts_paid_until', new Date(Date.now() - 30 * 864e5).toISOString()).order('alerts_paid_until'),
  ]) : [{ data: [] }, { data: [] }];
  const payIds = [...new Set((pays || []).map((p) => p.user_id))];
  const { data: payers } = payIds.length ? await sb.from('profiles').select('id,display_name,username,ib_verified').in('id', payIds) : { data: [] };
  const who = Object.fromEntries((payers || []).map((p) => [p.id, p]));
  const mailIds = [...new Set([...(queue || []).map((c) => c.id), ...payIds])];
  const { data: emails } = canDecide && mailIds.length ? await sb.rpc('admin_emails', { p_ids: mailIds }) : { data: {} };
  const explorer = (net, tx) => /TRC20|TRON/i.test(net) ? `https://tronscan.org/#/transaction/${tx}`
    : /BEP20|BSC/i.test(net) ? `https://bscscan.com/tx/${tx}`
    : /ERC20|ETH/i.test(net) ? `https://etherscan.io/tx/${tx}`
    : /BTC|BITCOIN/i.test(net) ? `https://mempool.space/tx/${tx}` : null;
  const { data: cands } = await sb.rpc('community_candidates', { p_min_trades: 20 });
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
          <div className="row">
            {canDecide && <a className="btn ghost" href="/admin/members">الأعضاء</a>}
            <a className="btn" href="/admin/new">+ توصية من المحلل</a>
          </div>
        </div>

        {canDecide && (
          <>
            {upgrades?.length > 0 && (<>
              <h2>طلبات الانتقال للغرفة الكبيرة <span className="badge sell">{upgrades.length}</span></h2>
              {upgrades.map((u) => (
                <div key={u.id} className="card hl grid" style={{ gap: 10 }}>
                  <div className="row" style={{ justifyContent: 'space-between' }}>
                    <div>
                      <b>{u.display_name}</b>
                      <div className="muted">{u.broker || '—'} · <span className="ltr">{u.broker_account || '—'}</span> · الرصيد المسجّل <span className="ltr">${u.balance_usd ?? '—'}</span> ← بيقول هلق <b className="ltr" style={{ color: 'var(--text)' }}>${u.upgrade_balance}</b> · {when(u.upgrade_requested_at)}</div>
                    </div>
                    {u.phone && <a className="btn ghost" href={`https://wa.me/${u.phone.replace(/[^0-9]/g, '')}`} target="_blank" rel="noopener"><span className="ltr">{u.phone}</span> · واتساب</a>}
                  </div>
                  <div className="grid g2">
                    <form action={setRoom} className="row">
                      <input type="hidden" name="id" value={u.id} /><input type="hidden" name="room" value="2" />
                      <input name="balance" type="number" defaultValue={u.upgrade_balance} required style={{ width: 130 }} dir="ltr" />
                      <button className="btn">تأكدت، انقله لغرفة 2</button>
                    </form>
                    <form action={setRoom} className="row">
                      <input type="hidden" name="id" value={u.id} /><input type="hidden" name="room" value="1" />
                      <button className="btn ghost">الرصيد مش كافي، خليه بغرفة 1</button>
                    </form>
                  </div>
                </div>
              ))}
            </>)}
            <h2>طلبات تفعيل العملاء {queue?.length ? <span className="badge sell">{queue.length}</span> : '(0)'}</h2>
            {(!queue || queue.length === 0) && <div className="card muted">ما في طلبات.</div>}
            {queue?.map((c) => (
              <div key={c.id} className="card hl grid" style={{ gap: 10 }}>
                <div className="row" style={{ justifyContent: 'space-between' }}>
                  <div>
                    <b>{c.display_name}</b>{' '}
                    {c.has_ib_account === false
                      ? <span className="badge" style={{ background: 'var(--gold)' }}>بدّه مساعدة بنقل/فتح حساب</span>
                      : <span className="badge buy">بيقول حسابه تحت وكالتنا</span>}
                    {emails?.[c.id] && <div className="ltr muted" style={{ textAlign: 'right' }}>{emails[c.id]}</div>}
                    <div className="muted">{c.broker || '—'} · <span className="ltr">{c.broker_account || '—'}</span>{c.reported_balance != null && <> · بيقول رصيده <b className="ltr" style={{ color: 'var(--text)' }}>${c.reported_balance}</b> ({c.reported_balance >= 1000 ? 'غرفة 2' : 'غرفة 1'})</>} · {when(c.activation_requested_at)}</div>
                  </div>
                  {c.phone && <a className="btn ghost" href={`https://wa.me/${c.phone.replace(/[^0-9]/g, '')}`} target="_blank" rel="noopener"><span className="ltr">{c.phone}</span> · واتساب</a>}
                </div>
                <div className="grid g2">
                  <form action={verifyClient} className="row">
                    <input type="hidden" name="id" value={c.id} />
                    <input name="balance" type="number" placeholder="الرصيد $" required style={{ width: 130 }} dir="ltr" defaultValue={c.reported_balance ?? ''} />
                    <button className="btn">فعّل</button>
                  </form>
                  <form action={rejectActivation} className="row">
                    <input type="hidden" name="id" value={c.id} />
                    <input name="note" placeholder="السبب (بيشوفه العميل)" style={{ flex: 1 }} />
                    <button className="btn red">رفض / إغلاق</button>
                  </form>
                </div>
              </div>
            ))}
          </>
        )}

        {canDecide && (
          <>
            <h2>اشتراكات التنبيهات (كريبتو) {pays?.length ? <span className="badge sell">{pays.length}</span> : '(0)'}</h2>
            {(!pays || pays.length === 0) && <div className="card muted">ما في دفعات بانتظار المراجعة.</div>}
            {pays?.map((p) => {
              const u = who[p.user_id] || {};
              const link = explorer(p.network, p.txid);
              return (
                <div key={p.id} className="card hl grid">
                  <div className="row" style={{ justifyContent: 'space-between' }}>
                    <div><b>{u.display_name || u.username || '—'}</b>{u.ib_verified && <span className="muted"> · عميل وكالة (مجاني أصلاً)</span>}
                      {emails?.[p.user_id] && <div className="ltr muted" style={{ textAlign: 'right' }}>{emails[p.user_id]}</div>}
                      <div className="muted">{p.network} · <span className="ltr">${p.amount_usd}</span> · <span>{p.days} يوم</span> · <span className="ltr">{when(p.created_at)}</span></div></div>
                    {link && <a className="btn ghost" href={link} target="_blank" rel="noopener">افحص التحويل ↗</a>}
                  </div>
                  <div className="ltr muted" style={{ wordBreak: 'break-all', fontFamily: 'monospace' }}>{p.txid}</div>
                  <div className="muted">تأكد: المبلغ كامل، على عنوان محفظتنا، والعملية ناجحة (Confirmed).</div>
                  <div className="grid g2">
                    <form action={approvePayment} className="row">
                      <input type="hidden" name="id" value={p.id} />
                      <input name="days" type="number" defaultValue={p.days} min={1} max={3660} style={{ width: 90 }} dir="ltr" />
                      <button className="btn green">وافق وفعّل</button>
                    </form>
                    <form action={rejectPayment} className="row">
                      <input type="hidden" name="id" value={p.id} />
                      <input name="note" placeholder="السبب (بيشوفه العميل)" style={{ flex: 1 }} />
                      <button className="btn red">ارفض</button>
                    </form>
                  </div>
                </div>
              );
            })}
            {subs?.length > 0 && (
              <div className="card" style={{ overflowX: 'auto' }}>
                <table>
                  <thead><tr><th>المشترك</th><th>لغاية</th><th></th></tr></thead>
                  <tbody>{subs.map((s) => {
                    const live = new Date(s.alerts_paid_until) > new Date();
                    return (
                      <tr key={s.id}>
                        <td>{s.display_name || s.username || '—'}</td>
                        <td className={live ? 'ok' : 'bad'}><span className="ltr">{when(s.alerts_paid_until)}</span>{live ? '' : ' (منتهي)'}</td>
                        <td>
                          <div className="row" style={{ flexWrap: 'nowrap' }}>
                            <form action={grantAlerts}><input type="hidden" name="id" value={s.id} /><input type="hidden" name="days" value="30" /><button className="btn ghost" style={{ minHeight: 32, padding: '0 10px' }}>+30 يوم</button></form>
                            {live && <form action={grantAlerts}><input type="hidden" name="id" value={s.id} /><input type="hidden" name="days" value="0" /><button className="btn red" style={{ minHeight: 32, padding: '0 10px' }}>إيقاف</button></form>}
                          </div>
                        </td>
                      </tr>
                    );
                  })}</tbody>
                </table>
              </div>
            )}
          </>
        )}

        {log && log.length > 0 && (
          <div className="note grid" style={{ gap: 4 }}>
            <b>السيستم اليوم:</b>
            {[...new Map(log.map((l) => [l.symbol, l])).values()].map((l) => (
              <div key={l.symbol}>
                <b>{symName(l.symbol)}:</b>{' '}
                {l.msg === 'suggestion created' ? 'طلّع اقتراح، شوفه تحت.'
                  : l.msg.includes('H1') ? 'ما في صفقة: اتجاه الساعة عكس الاتجاه اليومي.'
                  : l.msg.includes('beyond') ? 'ما في صفقة: السوق فتح بعد نقطة البيفوت.'
                  : l.msg.includes('history') ? 'ما في بيانات أسعار كافية لسا (جسر الأسعار).'
                  : l.msg}
                <span className="muted ltr"> · {new Date(l.t).toISOString().slice(0, 16).replace('T', ' ')} GMT</span>
              </div>
            ))}
          </div>
        )}

        {shadow && shadow.length > 0 && (
          <>
            <h2>وضع تجريبي (ما بيوصل للعملاء)</h2>
            {shadow.map((sh) => (
              <div key={sh.symbol} className="card grid">
                <div className="row" style={{ justifyContent: 'space-between' }}>
                  <b>{symName(sh.symbol)} · عكس ترند {symName(sh.ref)}</b>
                  <span className="muted">بيتسجّل وبيتتابع، بدون نشر ولا تيليغرام</span>
                </div>
                <table><tbody>
                  <tr><td></td><td className="muted">الاختبار التاريخي</td><td className="muted">الأداء الحقيقي لهلأ</td></tr>
                  <tr><td>صفقات</td><td>{sh.expected?.sample}</td><td>{sh.live?.closed} مسكّرة من {sh.live?.signals}</td></tr>
                  <tr><td>نسبة النجاح</td><td>{fmt(sh.expected?.win_rate, 1)}%</td><td>{sh.live?.win_rate == null ? '—' : `${fmt(sh.live.win_rate, 1)}%`}</td></tr>
                  <tr><td>متوسط R</td><td className="ltr">+{fmt(sh.expected?.avg_r, 3)}</td><td className="ltr">{sh.live?.avg_r == null ? '—' : fmt(sh.live.avg_r, 3)}</td></tr>
                  <tr><td>مجموع R</td><td></td><td className="ltr">{fmt(sh.live?.total_r, 2)}</td></tr>
                </tbody></table>
                {sh.recent?.length > 0 && (
                  <table>
                    <thead><tr><th>التاريخ</th><th>الاتجاه</th><th>الدخول</th><th>الستوب</th><th>الحالة</th><th>R</th></tr></thead>
                    <tbody>{sh.recent.map((r) => (
                      <tr key={r.id}>
                        <td className="ltr">{new Date(r.published_at).toISOString().slice(0, 10)}</td>
                        <td>{r.side === 'BUY' ? 'شراء' : 'بيع'}</td>
                        <td className="ltr">{r.entry}</td><td className="ltr">{r.stop_loss}</td>
                        <td>{STATE_AR[r.state] || r.state}</td>
                        <td className="ltr">{r.result_r_partial == null ? '—' : fmt(r.result_r_partial, 2)}</td>
                      </tr>))}
                    </tbody>
                  </table>
                )}
                <div className="muted">بعد 2–3 أشهر، إذا الأداء الحقيقي قريب من الاختبار، منضيفه للغرف.</div>
              </div>
            ))}
          </>
        )}

        <h2>اقتراحات بانتظار الموافقة ({pending?.length || 0})</h2>
        {(!pending || pending.length === 0) && <div className="card muted">ما في اقتراحات جديدة.</div>}
        {pending?.map((s) => (
          <div key={s.id} className="card grid">
            <div className="row" style={{ justifyContent: 'space-between' }}>
              <div className="row">
                <b>{symName(s.symbol)}</b>
                <span className={`badge ${s.side === 'BUY' ? 'buy' : 'sell'}`}>{s.side === 'BUY' ? 'شراء' : 'بيع'}</span>
                <span className="muted">{s.source === 'engine' ? 'من السيستم' : s.source === 'community' ? <>فكرة من العضو <span className="ltr">@{s.credit_username}</span></> : 'من المحلل'}</span>
              </div>
              <b className={s.check_passed ? 'ok' : 'bad'}>{s.check_passed ? 'عدّت الفحص ✓' : 'ما عدّت الفحص ✗'}</b>
            </div>
            <div className="kv">
              <div><span className="muted">الدخول</span><b>{px(s.symbol, s.entry)}</b></div>
              <div><span className="muted">الستوب</span><b className="bad">{px(s.symbol, s.stop_loss)}</b></div>
              <div><span className="muted">الهدف 1</span><b className="ok">{px(s.symbol, s.tp1)}</b></div>
              <div><span className="muted">الهدف 2</span><b className="ok">{px(s.symbol, s.tp2)}</b></div>
            </div>
            {s.hist_sample && (
              <div className="note">
                تاريخياً، الإعداد هاد: <b>{fmt(s.hist_win_rate, 0)}%</b> نجاح، متوسط <b className="ltr">{s.hist_avg_r > 0 ? '+' : ''}{fmt(s.hist_avg_r, 2)}R</b> على <b>{s.hist_sample}</b> صفقة.
                {s.risk_usd_001 ? <>المخاطرة <span className="ltr">${fmt(s.risk_usd_001, 2)}</span> لكل 0.01 لوت.</> : 'المخاطرة بالدولار مش محسوبة لهالأداة (حجم العقد بيختلف حسب الشركة).'}
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

        {canDecide && cands && cands.length > 0 && (
          <>
            <h2>أفكار مرشّحة من المجتمع ({cands.filter((c) => !c.promoted).length})</h2>
            <div className="muted">أوامر معلّقة لسا ما اتفعّلت، من أعضاء عندهم 20 فكرة مسكّرة أو أكتر ومتوسط R موجب.</div>
            {cands.map((c) => (
              <div key={c.id} className="card grid">
                <div className="row" style={{ justifyContent: 'space-between' }}>
                  <div className="row">
                    <b className="ltr">@{c.username}</b>
                    <span className="muted">{c.trades} فكرة · نجاح {fmt(c.win_rate, 0)}% · متوسط <span className="ltr">{fmt(c.avg_r, 2)}R</span></span>
                  </div>
                  <span className="muted ltr">{new Date(c.posted_at).toISOString().slice(0, 16).replace('T', ' ')}</span>
                </div>
                <div className="row">
                  <b>{symName(c.symbol)}</b>
                  <span className={`badge ${c.side === 'BUY' ? 'buy' : 'sell'}`}>{c.side === 'BUY' ? 'شراء' : 'بيع'}</span>
                  <span className="muted ltr">{c.order_type}</span>
                  <span className="ltr">@ {c.entry} · SL {c.stop_loss} · TP {c.take_profit}</span>
                </div>
                {c.note && <div className="note">{c.note}</div>}
                {c.promoted ? <div className="muted">انرشّحت ✓ (شوفها بقائمة الموافقة)</div> : (
                  <form action={promoteCommunity}>
                    <input type="hidden" name="id" value={c.id} />
                    <button className="btn ghost">رشّح للغرف (بتمر على الفحص والموافقة)</button>
                  </form>
                )}
              </div>
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
                  <td>{s.symbol}</td><td>{s.side === 'BUY' ? 'شراء' : 'بيع'}</td><td className="ltr">{px(s.symbol, s.entry)}</td>
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
