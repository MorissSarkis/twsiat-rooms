'use server';
import { redirect } from 'next/navigation';
import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase-server';

const ERR = { 'phone required': 'phone', 'bad phone': 'phone_bad', 'bad account': 'account' };

// one activation form for the alerts page and the rooms page
export async function submitActivation(formData) {
  const back = ['/rooms', '/home'].includes(String(formData.get('back') || '')) ? String(formData.get('back')) : '/alerts';
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
  const rb = Number(String(formData.get('reported_balance') || '').replace(/[^0-9.]/g, ''));
  if (!error && String(formData.get('reported_balance') || '').trim() !== '' && rb >= 0 && rb <= 1e8) {
    await sb.from('profiles').update({ reported_balance: Math.round(rb) }).eq('id', user.id);
  }
  revalidatePath('/alerts'); revalidatePath('/rooms'); revalidatePath('/home');
  if (error) {
    const key = Object.keys(ERR).find((k) => error.message.includes(k));
    redirect(`${back}?e=${key ? ERR[key] : 'act'}`);
  }
  redirect(`${back}?ok=act`);
}
