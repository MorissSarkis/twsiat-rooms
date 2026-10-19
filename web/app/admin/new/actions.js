'use server';
import { redirect } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase-server';

export async function submitSignal(prev, formData) {
  const sb = supabaseServer();
  const num = (k) => { const v = String(formData.get(k) || '').trim(); return v === '' ? null : Number(v); };
  const side = String(formData.get('side'));
  const kind = String(formData.get('kind'));
  const order_type = kind === 'MARKET' ? 'MARKET' : `${side}_${kind}`;
  const { data: id, error } = await sb.rpc('analyst_submit_signal', {
    p_symbol: String(formData.get('symbol')), p_side: side, p_order_type: order_type,
    p_entry: num('entry'), p_stop: num('stop'), p_tp1: num('tp1'), p_tp2: num('tp2'),
    p_valid_hours: num('hours') || 12, p_note: String(formData.get('note') || ''),
  });
  if (error) return { error: 'ما قدرنا نحفظ التوصية: ' + error.message };

  if (formData.get('publish') === '1') {
    const { data: { user } } = await sb.auth.getUser();
    const { data: me } = await sb.from('profiles').select('role').eq('id', user?.id).single();
    if (!me || !['manager', 'admin'].includes(me.role)) return { error: 'النشر المباشر لمدير الحساب بس. التوصية انحفظت بانتظار الموافقة.' };
    const rooms = formData.getAll('rooms').map(Number);
    if (rooms.length === 0) return { error: 'اختار غرفة وحدة على الأقل. التوصية انحفظت بانتظار الموافقة.' };
    const { data: chk } = await sb.rpc('suggestion_live_check', { p_id: id });
    if (chk && !chk.ok) return { error: 'ما انتشرت: ' + chk.reason + '. التوصية انحفظت بانتظار الموافقة.' };
    const { data: s } = await sb.from('suggestions').select('*').eq('id', id).single();
    await sb.from('suggestions').update({ status: 'approved', decided_by: user.id, decided_at: new Date().toISOString(), decision_note: 'نشر مباشر من مدير الحساب' }).eq('id', id);
    const { error: e2 } = await sb.from('signals').insert({
      suggestion_id: id, rooms, symbol: s.symbol, side: s.side, order_type: s.order_type,
      entry: s.entry, stop_loss: s.stop_loss, tp1: s.tp1, tp2: s.tp2, risk_usd_001: s.risk_usd_001, expires_at: s.expires_at,
    });
    if (e2) return { error: 'ما قدرنا ننشر: ' + e2.message };
  }
  redirect('/admin');
}
