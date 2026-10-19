import { createClient } from '@supabase/supabase-js';
// Telegram posts bot updates here. The database checks the secret header and does all the work.
export async function POST(request) {
  const secret = request.headers.get('x-telegram-bot-api-secret-token') || '';
  let update = null;
  try { update = await request.json(); } catch {}
  if (secret && update) {
    const sb = createClient(process.env.NEXT_PUBLIC_SUPABASE_URL, process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY, { auth: { persistSession: false } });
    await sb.rpc('tg_webhook', { p_secret: secret, p_update: update });
  }
  return new Response('ok');
}
