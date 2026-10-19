import { NextResponse } from 'next/server';
import { supabaseServer } from '@/lib/supabase-server';
import { siteOrigin } from '@/lib/origin';
export async function POST(request) {
  await supabaseServer().auth.signOut();
  return NextResponse.redirect(new URL('/login', siteOrigin(request)), { status: 303 });
}
