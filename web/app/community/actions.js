'use server';
import { revalidatePath } from 'next/cache';
import { supabaseServer } from '@/lib/supabase-server';

export async function setUsername(prev, formData) {
  const sb = supabaseServer();
  const { data: { user } } = await sb.auth.getUser();
  if (!user) return { error: 'سجّل دخول أول' };
  const u = String(formData.get('username') || '').trim();
  if (!/^[A-Za-z0-9_]{3,20}$/.test(u)) return { error: 'الاسم لازم يكون 3–20 حرف إنجليزي أو أرقام أو _' };
  const { error } = await sb.from('profiles').update({ username: u }).eq('id', user.id);
  if (error) return { error: error.code === '23505' ? 'هالاسم مأخوذ، جرّب غيره' : 'ما قدرنا نحفظ الاسم' };
  revalidatePath('/community');
  return { ok: true };
}

export async function postIdea(prev, formData) {
  const sb = supabaseServer();
  const num = (k) => { const v = String(formData.get(k) || '').trim(); return v === '' ? null : Number(v); };
  const side = String(formData.get('side'));
  const kind = String(formData.get('kind'));
  const { error } = await sb.rpc('community_post', {
    p_symbol: String(formData.get('symbol')),
    p_side: side,
    p_order_type: kind === 'MARKET' ? 'MARKET' : `${side}_${kind}`,
    p_entry: kind === 'MARKET' ? null : num('entry'),
    p_stop: num('stop'),
    p_tp: num('tp'),
    p_note: String(formData.get('note') || ''),
  });
  if (error) return { error: error.message };
  revalidatePath('/community');
  return { ok: true, at: Date.now() };
}
