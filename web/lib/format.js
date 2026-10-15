export const fmt = (n, d = 2) => (n == null ? '—' : Number(n).toLocaleString('en-US', { minimumFractionDigits: d, maximumFractionDigits: d }));
export function lotFor(balance, riskPct, riskUsd001) {
  if (!balance || !riskUsd001) return null;
  const lots = Math.floor(((balance * riskPct) / 100 / riskUsd001) * 0.01 * 100) / 100;
  return lots;
}
export const STATE_AR = { waiting: 'بانتظار التفعيل', open: 'مفتوحة', tp1: 'تحقق الهدف 1 · الستوب للدخول', tp2: 'تحقق الهدف 2', sl: 'ستوب لوس', be: 'خرجت على الدخول', expired: 'انتهت بدون تفعيل', closed: 'مغلقة' };
export const ROOM_AR = { 1: 'غرفة الحسابات الصغيرة · أقل من 1,000$', 2: 'غرفة الحسابات الكبيرة · 1,000$ وأكثر' };
export const SYMBOL_AR = { XAUUSD: 'الذهب' };
export const symName = (s) => SYMBOL_AR[s] || s;
export const ORDER_AR = { MARKET: 'بسعر السوق', BUY_LIMIT: 'Buy Limit', SELL_LIMIT: 'Sell Limit', BUY_STOP: 'Buy Stop', SELL_STOP: 'Sell Stop' };
export const CSTATE_AR = { waiting: 'أمر معلّق', open: 'مفتوحة', tp: 'تحقق الهدف ✅', sl: 'ستوب لوس ❌', expired: 'انتهى بدون تفعيل', closed: 'أُغلقت بعد 5 أيام' };
export const when = (t) => (t ? new Date(t).toLocaleString('en-GB', { timeZone: 'Asia/Riyadh', dateStyle: 'short', timeStyle: 'short' }) : '—');
