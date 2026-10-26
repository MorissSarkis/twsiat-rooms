'use server';
import { redirect } from 'next/navigation';
import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase-server';

const ERR = { 'phone required': 'phone', 'bad phone': 'phone_bad', 'bad account': 'account' };

// one activation form for the alerts page and the rooms page
export async function submitActivation(formData) {
  const back = String(formData.get('back') || '') === '/rooms' ? '/rooms' : '/alerts';
  const sb = supabaseServer();
  const { data: { user } } = await sb.auth.getUser();
  if (!user) redirect('/login?next=' + back);
  const hasIb = String(formData.get('has_ib')) === 'yes';
  const { error } = await sb.rpc('submit_activation', {
    p_broker: String(formData.get('broker') || ''),
    p_account: String(formData.get('account') || '').trim(),
    p_has_ib: hasIb,
    p_phone: String(formData.get('phone') || ''),
  });
  revalidatePath('/alerts'); revalidatePath('/rooms');
  if (error) {
    const key = Object.keys(ERR).find((k) => error.message.includes(k));
    redirect(`${back}?e=${key ? ERR[key] : 'act'}`);
  }
  redirect(`${back}?ok=act`);
}
