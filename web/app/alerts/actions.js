'use server';
import { redirect } from 'next/navigation';
import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase-server';
import { ALERTS_URL } from '@/lib/brand';

// one-time code (2 minutes) -> the alerts app signs this person in with it
export async function openAlerts() {
  const sb = supabaseServer();
  const { data: { user } } = await sb.auth.getUser();
  if (!user) redirect('/login?next=/alerts');
  const { data: code, error } = await sb.rpc('alerts_issue_code');
  if (error && /phone required/.test(error.message)) redirect('/home?e=phone_needed#phone');
  if (error || !code) redirect('/alerts?e=access');
  redirect(`${ALERTS_URL}/auth?code=${encodeURIComponent(code)}`);
}

const ERR = { 'bad txid': 'txid', 'bad network': 'network', 'too many pending': 'pending', 'txid already used': 'used' };

export async function submitPayment(formData) {
  const sb = supabaseServer();
  const { data: { user } } = await sb.auth.getUser();
  if (!user) redirect('/login?next=/alerts');
  const { error } = await sb.rpc('alerts_submit_payment', {
    p_network: String(formData.get('network') || ''),
    p_txid: String(formData.get('txid') || '').trim(),
  });
  revalidatePath('/alerts');
  if (error) {
    const key = Object.keys(ERR).find((k) => error.message.includes(k));
    redirect(`/alerts?e=${key ? ERR[key] : 'pay'}`);
  }
  redirect('/alerts?ok=paid');
}
