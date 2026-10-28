import webpush from 'web-push';
import { supabaseAnon } from '@/lib/supabase-anon';
// Called once by the database (db/029): create the VAPID keys and store them there.
export async function POST(request) {
  let body = {};
  try { body = await request.json(); } catch {}
  const sb = supabaseAnon();
  const { data: existing } = await sb.rpc('push_public_key');
  if (existing) return Response.json({ ok: true, existed: true });
  const k = webpush.generateVAPIDKeys();
  const { data: ok } = await sb.rpc('push_init_keys', { p_secret: String(body.secret || ''), p_public: k.publicKey, p_private: k.privateKey });
  return Response.json({ ok: !!ok });
}
