// Reads a block of signals written freely (WhatsApp style) or pasted from a sheet, e.g.
//   NASDAQ
//   BUY AT PRICE 26755        (or: BUY ATM / BUY NOW / شراء سعر السوق)
//   TP : 26960   TP 2 : 27050   TP 3 : 27530
//   SL : 26100
// Sheet rows need a header row: symbol, side, entry, tp1, tp2, tp3, sl (any order, entry empty = market).

const ALIASES = [
  [/^(NASDAQ|NAS ?100|US ?TECH|USTEC|ناسداك)/, 'USTEC'],
  [/^(US ?30|DOW|DJI|داو)/, 'US30'],
  [/^(US ?500|S ?& ?P|SPX|SP ?500)/, 'US500'],
  [/^(GERMAN|GER ?40|GER ?30|DAX|DE ?40|DE ?30|داكس)/, 'DE30'],
  [/^(UK ?100|FTSE)/, 'UK100'],
  [/^(JP ?225|NIKKEI|JAPAN)/, 'JP225'],
  [/^(GOLD|XAU|ذهب|الذهب)/, 'XAUUSD'],
  [/^(SILVER|XAG|فضة|الفضة)/, 'XAGUSD'],
  [/^(BRENT|UK ?OIL)/, 'UKOIL'],
  [/^(CRUDE|OIL|WTI|US ?OIL|نفط|النفط)/, 'USOIL'],
  [/^(NATURAL ?GAS|NAT ?GAS|GAS|XNG|غاز|الغاز)/, 'XNGUSD'],
  [/^(BTC|BITCOIN|بيتكوين)/, 'BTCUSD'],
  [/^(ETH|ETHEREUM|إيثيريوم|ايثيريوم)/, 'ETHUSD'],
  [/^(XRP|RIPPLE|ريبل)/, 'XRPUSD'],
  [/^(UNI|UNISWAP)/, 'UNIUSD'],
  [/^(MICROSOFT|MSFT|مايكروسوفت)/, 'MSFT'],
  [/^AMD/, 'AMD'],
  [/^(AMAZON|AMZN|أمازون|امازون)/, 'AMZN'],
  [/^(NETFLIX|NFLX|نتفليكس)/, 'NFLX'],
  [/^(NVIDIA|NVDA|إنفيديا)/, 'NVDA'],
];
const FX = ['EUR', 'GBP', 'AUD', 'NZD', 'USD', 'JPY', 'CHF', 'CAD'];

const num = (s) => { const v = Number(String(s).replace(/,/g, '').trim()); return Number.isFinite(v) && v > 0 ? v : null; };
const firstNum = (s) => { const m = String(s).replace(/(\d),(\d{3})/g, '$1$2').match(/\d+(?:\.\d+)?/); return m ? num(m[0]) : null; };
const SIDE_RE = /\b(B\s*U+\s*Y|SELL)\b|شراء|بيع/i;
const MARKET_RE = /\b(ATM|NOW|MARKET|MKT|CMP)\b|سعر السوق|ماركت|الآن|هلق/i;

export function symbolOf(line) {
  const u = line.toUpperCase().replace(/[^A-Z0-9&؀-ۿ ]/g, ' ').replace(/\s+/g, ' ').trim();
  const compact = u.replace(/ /g, '');
  if (/^[A-Z]{6}/.test(compact) && FX.includes(compact.slice(0, 3)) && FX.includes(compact.slice(3, 6))) return compact.slice(0, 6);
  for (const [re, code] of ALIASES) if (re.test(u)) return code;
  return null;
}

function sideOf(line) {
  const m = line.match(SIDE_RE);
  if (!m) return null;
  const t = m[0].toUpperCase();
  return t.includes('SELL') || m[0] === 'بيع' ? 'SELL' : 'BUY';
}

function parseSheet(lines) {
  const head = lines[0].split('\t').map((h) => h.trim().toLowerCase().replace(/\s+/g, ''));
  const col = (names) => head.findIndex((h) => names.includes(h));
  const ix = { sym: col(['symbol', 'instrument', 'الأداة', 'الاداة']), side: col(['side', 'direction', 'الاتجاه']),
    entry: col(['entry', 'price', 'الدخول']), tp1: col(['tp1', 'tp', 'الهدف1']), tp2: col(['tp2', 'الهدف2']),
    tp3: col(['tp3', 'الهدف3']), sl: col(['sl', 'stop', 'stoploss', 'الستوب']) };
  if (ix.sym < 0 || ix.side < 0) return null;
  return lines.slice(1).filter((l) => l.trim()).map((l, i) => {
    const c = l.split('\t'); const g = (k) => (ix[k] >= 0 ? c[ix[k]] || '' : '');
    return { n: i + 1, raw: l, symbolText: g('sym').trim(), symbol: symbolOf(g('sym')), side: sideOf(g('side')),
      market: !num(g('entry')), entry: num(g('entry')), tp1: num(g('tp1')), tp2: num(g('tp2')), tp3: num(g('tp3')), sl: num(g('sl')) };
  });
}

export function parseBatch(text) {
  const lines = String(text || '').replace(/\r/g, '').split('\n');
  const nonEmpty = lines.filter((l) => l.trim());
  if (nonEmpty.length && nonEmpty[0].includes('\t')) { const s = parseSheet(nonEmpty); if (s) return s; }
  const items = []; let cur = null;
  const start = (line, sym) => { cur = { n: items.length + 1, raw: '', symbolText: line.trim(), symbol: sym, side: null, market: false, entry: null, tp1: null, tp2: null, tp3: null, sl: null }; items.push(cur); };
  for (const line0 of lines) {
    const line = line0.trim();
    if (!line) continue;
    const up = line.toUpperCase();
    const tp = up.match(/^(?:TP|T\.P|TARGET|هدف|الهدف)\s*([123])?\s*[:=\-]?\s*(.*)$/i);
    const sl = up.match(/^(?:SL|S\.L|STOP(?:\s*LOSS)?|ستوب|وقف(?:\s*الخسارة)?)\s*[:=\-]?\s*(.*)$/i);
    if (cur && tp) {
      const v = firstNum(tp[2]); const k = tp[1] ? Number(tp[1]) : (!cur.tp1 ? 1 : !cur.tp2 ? 2 : 3);
      cur['tp' + k] = v; cur.raw += line + '\n'; continue;
    }
    if (cur && sl) { cur.sl = firstNum(sl[1]); cur.raw += line + '\n'; continue; }
    const side = sideOf(line);
    const sym = symbolOf(line);
    const takeSide = () => {
      cur.side = side; cur.market = MARKET_RE.test(line);
      cur.entry = cur.market ? null : firstNum(line.slice(line.search(SIDE_RE)).replace(SIDE_RE, ' '));
    };
    if (sym) {                       // instrument line, may also carry side and price: "GOLD BUY 4008"
      if (!cur || cur.side || cur.tp1 || cur.sl) start(line, sym); else { cur.symbol = sym; cur.symbolText = line; }
      cur.raw += line + '\n';
      if (side) takeSide();
      continue;
    }
    if (side) {                      // "BUY AT PRICE 26755" / "BUY ATM" (or "BUY GOLD 4008" without a line before)
      if (!cur || cur.side) start(line, symbolOf(line.replace(SIDE_RE, ' ')));
      takeSide(); cur.raw += line + '\n'; continue;
    }
    if (!cur) { start(line, null); cur.raw += line + '\n'; }
    else cur.raw += line + '\n';
  }
  return items;
}

// checks that don't need the live price; `entry` is the live price for market orders when known
export function checkItem(it, known, live) {
  const errs = [];
  if (!it.symbol) errs.push('ما عرفنا الأداة');
  else if (known && !known.includes(it.symbol)) errs.push('الأداة مش موجودة بالغرف');
  if (!it.side) errs.push('ناقص الاتجاه (BUY / SELL)');
  if (!it.tp1) errs.push('ناقص الهدف 1');
  if (!it.sl) errs.push('ناقص الستوب');
  if (!it.market && !it.entry) errs.push('ناقص سعر الدخول (أو اكتب ATM للسوق)');
  const e = it.market ? live : it.entry;
  if (errs.length || !e) return errs;
  const buy = it.side === 'BUY';
  const far = (x) => x && Math.abs(x - e) > 0.2 * e;
  if (buy ? !(it.sl < e) : !(it.sl > e)) errs.push(`الستوب لازم يكون ${buy ? 'تحت' : 'فوق'} الدخول`);
  if (buy ? !(it.tp1 > e) : !(it.tp1 < e)) errs.push(`الهدف 1 لازم يكون ${buy ? 'فوق' : 'تحت'} الدخول`);
  if (it.tp2 && (buy ? it.tp2 <= it.tp1 : it.tp2 >= it.tp1)) errs.push('الهدف 2 لازم يكون أبعد من الهدف 1');
  if (it.tp3 && !it.tp2) errs.push('في هدف 3 بدون هدف 2');
  if (it.tp3 && it.tp2 && (buy ? it.tp3 <= it.tp2 : it.tp3 >= it.tp2)) errs.push('الهدف 3 لازم يكون أبعد من الهدف 2');
  if ([it.sl, it.tp1, it.tp2, it.tp3].some(far)) errs.push('رقم بعيد أكتر من 20% عن السعر، غالباً غلط بالفاصلة');
  const fx = /^[A-Z]{6}$/.test(it.symbol) && FX.includes(it.symbol.slice(0, 3));
  if (fx && [it.sl, it.tp1, it.tp2, it.tp3].some((x) => x && Math.abs(x - e) > 0.03 * e)) errs.push('رقم بعيد أكتر من 3% عن السعر، كبير على زوج عملات، غالباً غلط');
  if (!it.market && live && Math.abs(it.entry - live) > 0.1 * live) errs.push('سعر الدخول بعيد أكتر من 10% عن السعر الحالي');
  return errs;
}

export const orderTypeOf = (it, live) => (it.market ? 'MARKET' : it.side + ((it.side === 'BUY') === (it.entry < live) ? '_LIMIT' : '_STOP'));
