'use server';
import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase-server';
import { DISCLAIMER_VERSION } from '@/lib/disclaimer';
import { BROKERS } from '@/lib/brand';

export async function requestActivation(formData) {
  const sb = supabaseServer();
  const { data: { user } } = await sb.auth.getUser();
  if (!user) return;
  const broker = String(formData.get('broker') || '');
  const account = String(formData.get('account') || '').trim();
  if (!BROKERS.includes(broker) || !/^[0-9]{4,15}$/.test(account)) return;
  await sb.from('profiles').update({
    broker, broker_account: account,
    activation_requested_at: new Date().toISOString(),
  }).eq('id', user.id);
  revalidatePath('/rooms');
  revalidatePath('/alerts');
}

export async function acceptDisclaimer(formData) {
  const sb = supabaseServer();
  const { data: { user } } = await sb.auth.getUser();
  if (!user) return;
  await sb.from('consents').insert({ user_id: user.id, room: Number(formData.get('room')), version: DISCLAIMER_VERSION });
  revalidatePath('/rooms');
}
