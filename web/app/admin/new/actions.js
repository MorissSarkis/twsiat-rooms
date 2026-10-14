'use server';
import { redirect } from 'next/navigation';
import { supabaseServer } from '@/lib/supabase-server';

export async function submitSignal(prev, formData) {
  const sb = supabaseServer();
  const num = (k) => { const v = String(formData.get(k) || '').trim(); return v === '' ? null : Number(v); };
  const side = String(formData.get('side'));
  const kind = String(formData.get('kind'));
  const order_type = kind === 'MARKET' ? 'MARKET' : `${side}_${kind}`;
  const { error } = await sb.rpc('analyst_submit_signal', {
    p_symbol: String(formData.get('symbol')), p_side: side, p_order_type: order_type,
    p_entry: num('entry'), p_stop: num('stop'), p_tp1: num('tp1'), p_tp2: num('tp2'),
    p_valid_hours: num('hours') || 12, p_note: String(formData.get('note') || ''),
  });
  if (error) return { error: 'ما قدرنا نحفظ التوصية: ' + error.message };
  redirect('/admin');
}
