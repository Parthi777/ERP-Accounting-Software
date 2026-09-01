import { NextResponse } from 'next/server';

import { isSupabaseConfigured } from '@/config/env';
import { createSupabaseServerClient } from '@/lib/supabase/server';

export const dynamic = 'force-dynamic';

/**
 * Railway health check (see railway.json).
 *
 * Returns 200 even when Supabase is unconfigured or unreachable, so a first
 * deploy passes its health check and serves /setup rather than crash-looping
 * before anyone can add the environment variables. The body carries the detail.
 *
 * `databaseMs` is the round trip to Supabase measured from inside the container,
 * which is the only place it can be measured honestly: the app's own latency to
 * the database dominates page render time, and from a browser it is invisible
 * behind edge PoPs. A number far above ~30ms means the app and the database are
 * in different regions, and no amount of query tuning will fix that.
 *
 * Deliberately reports no data and no configuration values — this endpoint is
 * public.
 */
export async function GET() {
  let firstMs: number | null = null;
  let warmMs: number | null = null;
  let databaseOk = false;

  if (isSupabaseConfigured) {
    try {
      const supabase = await createSupabaseServerClient();

      // Two probes, because they measure different things. The first pays the
      // TLS handshake, so it reflects what the very first query of a cold
      // request costs. The second reuses the connection, which is what every
      // subsequent query on a page actually pays — and that is the number to
      // judge a region pairing by.
      //
      // `head: true` is deliberately NOT used: PostgREST returns no body for a
      // head request, so the error arrives as `{ message: '' }` with no code and
      // there is no way to tell a refusal from a dead socket.
      const probe = async () => {
        const started = performance.now();
        const { error } = await supabase.from('permissions').select('code').limit(1);
        return { ms: Math.round(performance.now() - started), error };
      };

      const first = await probe();
      const warm = await probe();
      firstMs = first.ms;
      warmMs = warm.ms;

      // "Reachable" means the database answered, not that the query was allowed.
      // This endpoint is public, so the request arrives as `anon`, which by
      // design holds no table grants (0011 grants to `authenticated` only) and
      // is refused with 42501. That is a healthy database refusing correctly.
      // Only a transport failure means unreachable, and that throws.
      databaseOk = !first.error || typeof first.error.code === 'string';
    } catch {
      databaseOk = false;
    }
  }

  return NextResponse.json({
    status: 'ok',
    configured: isSupabaseConfigured,
    database: { reachable: databaseOk, firstQueryMs: firstMs, warmQueryMs: warmMs },
    version: '1.0.0',
    timestamp: new Date().toISOString(),
  });
}
