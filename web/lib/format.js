export const fmt = (n, d = 2) => (n == null ? '—' : Number(n).toLocaleString('en-US', { minimumFractionDigits: d, maximumFractionDigits: d }));
export function lotFor(balance, riskPct, riskUsd001) {
  if (!balance || !riskUsd001) return null;
  const lots = Math.floor(((balance * riskPct) / 100 / riskUsd001) * 0.01 * 100) / 100;
  return lots;
}
export const STATE_AR = { waiting: 'بانتظار التفعيل', open: 'مفتوحة', tp1: 'تحقق الهدف 1 · الستوب للدخول', tp2: 'تحقق الهدف 2', sl: 'ستوب لوس', be: 'خرجت على الدخول', expired: 'انتهت بدون تفعيل', closed: 'مغلقة' };
export const ROOM_AR = { 1: 'غرفة الحسابات الصغيرة · أقل من 1,000$', 2: 'غرفة الحسابات الكبيرة · 1,000$ وأكثر' };
