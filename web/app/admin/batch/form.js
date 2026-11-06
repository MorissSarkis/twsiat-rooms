'use client';
import { useState } from 'react';
import { parseBatch, checkItem, orderTypeOf } from '@/lib/batch';
import { previewPrices, publishBatch } from './actions';

const EXAMPLE = `GOLD
BUY AT PRICE 4008
TP : 4063
TP 2 : 4097
TP 3 : 4131
SL : 3950

GBPUSD
BUY ATM
TP : 1.3444
TP 2 : 1.3466
SL : 1.3320`;

const OT = { MARKET: 'سعر السوق', BUY_LIMIT: 'Buy Limit', BUY_STOP: 'Buy Stop', SELL_LIMIT: 'Sell Limit', SELL_STOP: 'Sell Stop' };

export default function BatchForm({ symbols }) {
  const codes = symbols.map((s) => s.code);
  const nameOf = (c) => symbols.find((s) => s.code === c)?.name || c;
  const [text, setText] = useState('');
  const [items, setItems] = useState(null);
  const [prices, setPrices] = useState({});
  const [pick, setPick] = useState({});
  const [rooms, setRooms] = useState([1, 2]);
  const [hours, setHours] = useState(24);
  const [busy, setBusy] = useState(false);
  const [result, setResult] = useState(null);

  const liveFor = (it) => { const p = prices[it.symbol]; return p ? (it.side === 'BUY' ? p.close + p.spread : p.close) : null; };
  const errsOf = (it) => checkItem(it, codes, liveFor(it));

  async function read() {
    setResult(null);
    const list = parseBatch(text);
    setItems(list);
    setBusy(true);
    try {
      const p = await previewPrices(list.map((i) => i.symbol));
      setPrices(p);
      const sel = {};
      for (const it of list) { const pr = p[it.symbol]; const live = pr ? (it.side === 'BUY' ? pr.close + pr.spread : pr.close) : null;
        sel[it.n] = !!pr && checkItem(it, codes, live).length === 0; }
      setPick(sel);
    } finally { setBusy(false); }
  }

  async function publish() {
    const chosen = items.filter((it) => pick[it.n]);
    if (!chosen.length) return;
    setBusy(true);
    try { setResult(await publishBatch(chosen, rooms, hours)); } finally { setBusy(false); }
  }

  const room = (r) => setRooms((x) => (x.includes(r) ? x.filter((y) => y !== r) : [...x, r].sort()));
  const nPick = items ? items.filter((it) => pick[it.n]).length : 0;

  return (
    <main className="wrap grid" style={{ maxWidth: 900 }}>
      <h1>نشر دفعة توصيات</h1>
      <div className="note">الصق التوصيات متل ما بتنكتب على الواتساب، أو انسخ صفوف من شيت (أول صف: symbol, side, entry, tp1, tp2, tp3, sl، والدخول الفاضي = سعر السوق). <b>AT PRICE</b> = أمر معلّق، <b>ATM</b> = سعر السوق.</div>
      <textarea value={text} onChange={(e) => { setText(e.target.value); setItems(null); setResult(null); }} rows={14} dir="ltr" placeholder={EXAMPLE} style={{ fontFamily: 'monospace' }} />
      <button className="btn" onClick={read} disabled={busy || !text.trim()}>{busy && !items ? 'جاري القراءة…' : 'اقرأ وافحص'}</button>

      {items && (
        <div className="card grid" style={{ gap: 10 }}>
          <h2>المعاينة ({items.length})</h2>
          <div style={{ overflowX: 'auto' }}>
            <table>
              <thead><tr><th></th><th>#</th><th>الأداة</th><th>الاتجاه</th><th>النوع</th><th>الدخول</th><th>الستوب</th><th>الهدف 1</th><th>الهدف 2</th><th>الهدف 3</th><th>السعر الحالي</th><th>الفحص</th></tr></thead>
              <tbody>
                {items.map((it) => {
                  const errs = errsOf(it); const live = liveFor(it); const p = prices[it.symbol];
                  const ok = errs.length === 0 && !!p;
                  return (
                    <tr key={it.n}>
                      <td><input type="checkbox" style={{ width: 'auto' }} disabled={!ok} checked={!!pick[it.n] && ok} onChange={(e) => setPick({ ...pick, [it.n]: e.target.checked })} /></td>
                      <td>{it.n}</td>
                      <td>{it.symbol ? nameOf(it.symbol) : <span className="bad">{it.symbolText}</span>}</td>
                      <td className={it.side === 'BUY' ? 'ok' : 'bad'}>{it.side === 'BUY' ? 'شراء' : it.side === 'SELL' ? 'بيع' : '—'}</td>
                      <td>{p && it.side ? OT[orderTypeOf(it, p.close)] : '—'}</td>
                      <td className="ltr">{it.market ? (live ?? '—') : it.entry ?? '—'}</td>
                      <td className="ltr bad">{it.sl ?? '—'}</td>
                      <td className="ltr ok">{it.tp1 ?? '—'}</td>
                      <td className="ltr ok">{it.tp2 ?? '—'}</td>
                      <td className="ltr ok">{it.tp3 ?? '—'}</td>
                      <td className="ltr muted">{p ? p.close : 'ما في سعر'}</td>
                      <td>{ok ? <span className="ok">✓ جاهزة</span> : <span className="bad">{(p || !it.symbol ? errs : ['ما في سعر حي لهالأداة', ...errs]).join(' · ')}</span>}</td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
          <div className="row" style={{ gap: 16, flexWrap: 'wrap' }}>
            <label className="row" style={{ gap: 6 }}><input type="checkbox" style={{ width: 'auto' }} checked={rooms.includes(1)} onChange={() => room(1)} /> غرفة 1</label>
            <label className="row" style={{ gap: 6 }}><input type="checkbox" style={{ width: 'auto' }} checked={rooms.includes(2)} onChange={() => room(2)} /> غرفة 2</label>
            <label className="row" style={{ gap: 6 }}>الأوامر المعلّقة صالحة <input type="number" value={hours} min={1} max={168} onChange={(e) => setHours(e.target.value)} style={{ width: 70 }} dir="ltr" /> ساعة</label>
          </div>
          {!result && <button className="btn green" onClick={publish} disabled={busy || !nPick || !rooms.length}>{busy ? 'جاري النشر…' : `انشر ${nPick} توصية`}</button>}
          {result && (
            <div className="grid" style={{ gap: 6 }}>
              {result.map((r) => <div key={r.n} className={r.ok ? 'note ok' : 'err'}>#{r.n} {r.ok ? '✅' : '❌'} {r.text}</div>)}
              <button className="btn ghost" onClick={() => { setText(''); setItems(null); setResult(null); }}>دفعة جديدة</button>
            </div>
          )}
        </div>
      )}
    </main>
  );
}
