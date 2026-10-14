import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
export async function GET(request) {
  const url = new URL(request.url);
  const code = url.searchParams.get('code');
  if (code) await supabaseServer().auth.exchangeCodeForSession(code);
  return NextResponse.redirect(new URL('/rooms', request.url));
}
