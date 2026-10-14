'use server';
import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase-server';
import { DISCLAIMER_VERSION } from '@/lib/disclaimer';

export async function requestActivation(formData) {
  const sb = supabaseServer();
  const { data: { user } } = await sb.auth.getUser();
  if (!user) return;
  await sb.from('profiles').update({
    broker: String(formData.get('broker') || ''),
    broker_account: String(formData.get('account') || '').trim(),
    activation_requested_at: new Date().toISOString(),
  }).eq('id', user.id);
  revalidatePath('/rooms');
}

export async function acceptDisclaimer(formData) {
  const sb = supabaseServer();
  const { data: { user } } = await sb.auth.getUser();
  if (!user) return;
  await sb.from('consents').insert({ user_id: user.id, room: Number(formData.get('room')), version: DISCLAIMER_VERSION });
  revalidatePath('/rooms');
}
