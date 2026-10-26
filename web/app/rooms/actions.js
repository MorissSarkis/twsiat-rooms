'use server';
import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase-server';
import { DISCLAIMER_VERSION } from '@/lib/disclaimer';

export async function acceptDisclaimer(formData) {
  const sb = supabaseServer();
  const { data: { user } } = await sb.auth.getUser();
  if (!user) return;
  await sb.from('consents').insert({ user_id: user.id, room: Number(formData.get('room')), version: DISCLAIMER_VERSION });
  revalidatePath('/rooms');
}
