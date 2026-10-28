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

export async function requestUpgrade(formData) {
  const sb = supabaseServer();
  const bal = Number(String(formData.get('balance') || '').replace(/[^0-9.]/g, ''));
  const { error } = await sb.rpc('request_room_upgrade', { p_balance: bal });
  revalidatePath('/rooms');
  if (error) return { error: 'اكتب رصيد 1,000$ أو أكثر' };
}
