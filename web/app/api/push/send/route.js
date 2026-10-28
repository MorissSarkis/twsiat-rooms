import webpush from 'web-push';
import { supabaseAnon } from '@/lib/supabase-anon';
// Called by the database (push_send) for each notification: look up the phones, encrypt, send.
export async function POST(request) {
  let m = {};
  try { m = await request.json(); } catch {}
  if (!m.secret || !Array.isArray(m.users)) return new Response('bad', { status: 400 });
  const sb = supabaseAnon();
  const { data: t } = await sb.rpc('push_targets', { p_secret: String(m.secret), p_users: m.users });
  if (!t || !t.public || !t.private) return new Response('no', { status: 403 });
  const payload = JSON.stringify({ title: m.title, body: m.body, url: m.url || '/rooms', tag: m.tag || undefined });
  const opts = { vapidDetails: { subject: 'mailto:info@twsiat.com', publicKey: t.public, privateKey: t.private }, TTL: 6 * 3600, urgency: 'high' };
  const gone = [];
  await Promise.all((t.subs || []).map((s) => webpush.sendNotification(s, payload, opts).catch((e) => {
    if (e && (e.statusCode === 404 || e.statusCode === 410)) gone.push(s.endpoint);
  })));
  if (gone.length) await sb.rpc('push_gone', { p_secret: String(m.secret), p_endpoints: gone });
  return Response.json({ sent: (t.subs || []).length - gone.length, gone: gone.length });
}
