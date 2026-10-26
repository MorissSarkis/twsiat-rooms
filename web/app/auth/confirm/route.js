import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import { siteOrigin } from '@/lib/origin';
// Email links point here (our own domain) instead of supabase.co — better for spam filters.
// Template link: {{ .SiteURL }}auth/confirm?token_hash={{ .TokenHash }}&type=<signup|recovery|invite|magiclink|email_change>
const TYPES = ['signup', 'email', 'recovery', 'invite', 'magiclink', 'email_change'];
export async function GET(request) {
  const url = new URL(request.url);
  const base = siteOrigin(request);
  const token_hash = url.searchParams.get('token_hash');
  const type = url.searchParams.get('type');
  if (!token_hash || !TYPES.includes(type)) return NextResponse.redirect(new URL('/login?e=link', base));
  const { error } = await supabaseServer().auth.verifyOtp({ type, token_hash });
  if (error) return NextResponse.redirect(new URL('/login?e=link', base));
  return NextResponse.redirect(new URL(type === 'recovery' ? '/reset' : '/home', base));
}
