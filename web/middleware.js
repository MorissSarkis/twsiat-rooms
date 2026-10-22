import { NextResponse } from 'next/server';
import { createServerClient } from '@supabase/ssr';
import { siteOrigin } from './lib/origin';
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
  if (!user && ['/rooms', '/admin', '/community', '/levels', '/alerts'].some((x) => p.startsWith(x))) {
    const to = new URL('/login', siteOrigin(request));
    if (p !== '/rooms') to.searchParams.set('next', p);
    return NextResponse.redirect(to);
  }
  return response;
}
export const config = { matcher: ['/((?!_next/static|_next/image|favicon.ico).*)'] };
