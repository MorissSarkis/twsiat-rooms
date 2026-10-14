import { NextResponse } from 'next/server';
import { createServerClient } from '@supabase/ssr';
export async function middleware(request) {
  let response = NextResponse.next({ request });
  const sb = createServerClient(process.env.NEXT_PUBLIC_SUPABASE_URL, process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY, {
    cookies: {
      getAll: () => request.cookies.getAll(),
      setAll: (list) => {
        list.forEach(({ name, value }) => request.cookies.set(name, value));
        response = NextResponse.next({ request });
        list.forEach(({ name, value, options }) => response.cookies.set(name, value, options));
      },
    },
  });
  const { data: { user } } = await sb.auth.getUser();
  const p = request.nextUrl.pathname;
  if (!user && (p.startsWith('/rooms') || p.startsWith('/admin'))) {
    const url = request.nextUrl.clone(); url.pathname = '/login'; return NextResponse.redirect(url);
  }
  return response;
}
export const config = { matcher: ['/((?!_next/static|_next/image|favicon.ico).*)'] };
