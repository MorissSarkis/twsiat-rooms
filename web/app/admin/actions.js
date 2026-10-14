'use server';
import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase-server';

async function staff() {
  const sb = supabaseServer();
  const { data: { user } } = await sb.auth.getUser();
  const { data: p } = await sb.from('profiles').select('role').eq('id', user?.id).single();
  if (!p || !['manager', 'admin'].includes(p.role)) throw new Error('not allowed');
  return { sb, user };
}

export async function approveSuggestion(formData) {
  const { sb, user } = await staff();
  const id = Number(formData.get('id'));
  const rooms = formData.getAll('rooms').map(Number);
  const { data: s } = await sb.from('suggestions').select('*').eq('id', id).single();
  if (!s || s.status !== 'pending' || rooms.length === 0) return;
  await sb.from('suggestions').update({ status: 'approved', decided_by: user.id, decided_at: new Date().toISOString(), decision_note: String(formData.get('note') || '') }).eq('id', id);
  await sb.from('signals').insert({
    suggestion_id: id, rooms, symbol: s.symbol, side: s.side, order_type: s.order_type,
    entry: s.entry, stop_loss: s.stop_loss, tp1: s.tp1, tp2: s.tp2, risk_usd_001: s.risk_usd_001, expires_at: s.expires_at,
  });
  revalidatePath('/admin');
}

export async function rejectSuggestion(formData) {
  const { sb, user } = await staff();
  await sb.from('suggestions').update({ status: 'rejected', decided_by: user.id, decided_at: new Date().toISOString(), decision_note: String(formData.get('note') || '') }).eq('id', Number(formData.get('id')));
  revalidatePath('/admin');
}

export async function verifyClient(formData) {
  const { sb, user } = await staff();
  const balance = Number(formData.get('balance'));
  await sb.from('profiles').update({
    ib_verified: true, balance_usd: balance, room: balance >= 1000 ? 2 : 1,
    verified_at: new Date().toISOString(), verified_by: user.id,
  }).eq('id', String(formData.get('id')));
  revalidatePath('/admin');
}
