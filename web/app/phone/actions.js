'use server';
import { redirect } from 'next/navigation';
import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase-server';

export async function savePhone(formData) {
  const sb = supabaseServer();
  const { data: { user } } = await sb.auth.getUser();
  if (!user) redirect('/login');
  const { error } = await sb.rpc('set_my_phone', { p_phone: String(formData.get('phone') || '') });
  revalidatePath('/home');
  redirect(error ? '/home?e=phone_bad#phone' : '/home?ok=phone');
}
