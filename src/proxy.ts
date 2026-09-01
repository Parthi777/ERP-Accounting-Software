import { createServerClient } from '@supabase/ssr';
import { NextResponse, type NextRequest } from 'next/server';

import { isSupabaseConfigured, publicEnv } from '@/config/env';

/** Routes reachable without a session. */
const PUBLIC_PATHS = ['/login', '/forgot-password', '/reset-password', '/setup', '/api/health'];

function isPublicPath(pathname: string): boolean {
  return PUBLIC_PATHS.some((path) => pathname === path || pathname.startsWith(`${path}/`));
}

/**
 * Refreshes the Supabase session cookie on every request and keeps
 * unauthenticated traffic out of the application shell.
 *
 * Next 16 renamed this convention from `middleware` to `proxy`; the behaviour is
 * unchanged.
 *
 * This is a convenience gate, not the security boundary. Authorization is decided
 * by `getTenantContext()` in the service layer and by RLS in the database (spec
 * §47) — a request that slips past this check still cannot read another tenant's
 * data.
 */
export default async function proxy(request: NextRequest) {
  const { pathname } = request.nextUrl;

  // Without Supabase configured there is nothing to authenticate against; send
  // everything to the setup page rather than failing on every route.
  if (!isSupabaseConfigured) {
    if (pathname === '/setup' || pathname === '/api/health') {
      return NextResponse.next();
    }
    const url = request.nextUrl.clone();
    url.pathname = '/setup';
    url.search = '';
    return NextResponse.redirect(url);
  }

  let response = NextResponse.next({ request });

  const supabase = createServerClient(publicEnv.supabaseUrl, publicEnv.supabaseAnonKey, {
    cookies: {
      getAll() {
        return request.cookies.getAll();
      },
      setAll(cookiesToSet) {
        for (const { name, value } of cookiesToSet) {
          request.cookies.set(name, value);
        }
        response = NextResponse.next({ request });
        for (const { name, value, options } of cookiesToSet) {
          response.cookies.set(name, value, options);
        }
      },
    },
  });

  // getUser() revalidates the token with Supabase. getSession() would trust the
  // cookie as-is, which is exactly what an auth gate must not do.
  //
  // A network failure here must not 500 every route in the application. Treating
  // an unreachable auth service as "not signed in" fails closed: the visitor is
  // sent to /login rather than being waved through.
  let user = null;
  try {
    const { data } = await supabase.auth.getUser();
    user = data.user;
  } catch (error) {
    console.error('[proxy] could not verify the session', error);
  }

  if (!user && !isPublicPath(pathname)) {
    const url = request.nextUrl.clone();
    url.pathname = '/login';
    // Preserve where they were headed so login can return them there.
    url.search = pathname === '/' ? '' : `?next=${encodeURIComponent(pathname)}`;
    return NextResponse.redirect(url);
  }

  if (user && (pathname === '/login' || pathname === '/')) {
    const url = request.nextUrl.clone();
    url.pathname = '/dashboard';
    url.search = '';
    return NextResponse.redirect(url);
  }

  return response;
}

export const config = {
  matcher: [
    /*
     * Everything except static assets and image files. Auth callbacks under
     * /api are included deliberately — they need the refreshed session.
     */
    '/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp|ico)$).*)',
  ],
};
