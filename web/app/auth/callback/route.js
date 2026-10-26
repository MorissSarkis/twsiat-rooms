import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import { siteOrigin } from '@/lib/origin';
export async function GET(request) {
  const url = new URL(request.url);
  const base = siteOrigin(request);
  const code = url.searchParams.get('code');
  const next = url.searchParams.get('next');
  const dest = next && /^\/[a-z]/.test(next) ? next : '/home';   // only same-site paths
  if (code) {
    const { error } = await supabaseServer().auth.exchangeCodeForSession(code);
    if (error) return NextResponse.redirect(new URL('/login?e=link', base));
  }
  return NextResponse.redirect(new URL(dest, base));
}
