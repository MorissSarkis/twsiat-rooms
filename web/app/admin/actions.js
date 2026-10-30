'use server';
import { revalidatePath } from 'next/cache';
import { redirect } from 'next/navigation';
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
  const { data: chk } = await sb.rpc('suggestion_live_check', { p_id: id });
  if (chk && !chk.ok) { revalidatePath('/admin'); return; }   // entry already reached: never publish a stale order
  await sb.from('suggestions').update({ status: 'approved', decided_by: user.id, decided_at: new Date().toISOString(), decision_note: String(formData.get('note') || '') }).eq('id', id);
  await sb.from('signals').insert({
    suggestion_id: id, rooms, symbol: s.symbol, side: s.side, order_type: s.order_type,
    entry: s.entry, stop_loss: s.stop_loss, tp1: s.tp1, tp2: s.tp2, risk_usd_001: s.risk_usd_001, expires_at: s.expires_at, credit_username: s.credit_username,
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

export async function promoteCommunity(formData) {
  const { sb } = await staff();
  await sb.rpc('promote_community', { p_id: Number(formData.get('id')) });
  revalidatePath('/admin');
}

// ---------- pivot alerts subscriptions (crypto) ----------
export async function approvePayment(formData) {
  const { sb } = await staff();
  const days = Number(formData.get('days'));
  await sb.rpc('alerts_approve_payment', { p_id: Number(formData.get('id')), p_days: days > 0 ? days : null });
  revalidatePath('/admin');
}

export async function rejectPayment(formData) {
  const { sb } = await staff();
  await sb.rpc('alerts_reject_payment', { p_id: Number(formData.get('id')), p_note: String(formData.get('note') || '') || null });
  revalidatePath('/admin');
}

export async function grantAlerts(formData) {
  const { sb } = await staff();
  await sb.rpc('alerts_grant_days', { p_user: String(formData.get('id')), p_days: Number(formData.get('days')) });
  revalidatePath('/admin');
}

// free alerts for any number of days (extends the trial; 0 ends it)
export async function extendTrial(formData) {
  const { sb } = await staff();
  const days = Math.max(0, Math.min(3660, parseInt(formData.get('days'), 10) || 0));
  await sb.rpc('admin_extend_trial', { p_user: String(formData.get('id')), p_days: days });
  revalidatePath('/admin/members');
  revalidatePath('/admin');
}

// close an activation request with a reason the member sees (not under our agency, wrong number, ...)
export async function rejectActivation(formData) {
  const { sb } = await staff();
  await sb.rpc('admin_reject_activation', { p_user: String(formData.get('id')), p_note: String(formData.get('note') || '') });
  revalidatePath('/admin');
}

// admin only: make someone team (analyst / manager / admin) or back to client
export async function setRole(formData) {
  const { sb } = await staff();
  await sb.rpc('admin_set_role', { p_user: String(formData.get('id')), p_role: String(formData.get('role')) });
  revalidatePath('/admin/members');
}

// move a member between room 1 and room 2 (also answers an upgrade request)
export async function setRoom(formData) {
  const { sb } = await staff();
  const bal = formData.get('balance');
  await sb.rpc('admin_set_room', { p_user: String(formData.get('id')), p_room: Number(formData.get('room')),
    p_balance: bal === null || bal === '' ? null : Number(bal) });
  revalidatePath('/admin'); revalidatePath('/admin/members');
}

// update a live signal: move stop / targets, add a comment, or close it now
export async function updateSignal(formData) {
  const { sb } = await staff();
  const num = (k) => { const v = String(formData.get(k) || '').trim(); return v === '' ? null : Number(v); };
  const close = formData.get('close') === '1';
  if (close && formData.get('sure') !== '1') redirect('/admin?uerr=' + encodeURIComponent('علّم على «متأكد» لتسكّر الصفقة') + '#live');
  const { error } = await sb.rpc('staff_update_signal', {
    p_id: Number(formData.get('id')), p_sl: close ? null : num('sl'), p_tp1: close ? null : num('tp1'), p_tp2: close ? null : num('tp2'),
    p_note: String(formData.get('note') || ''), p_close: close,
  });
  revalidatePath('/admin'); revalidatePath('/rooms');
  redirect(error ? '/admin?uerr=' + encodeURIComponent(error.message) + '#live' : '/admin?uok=1#live');
}
