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
  let databaseMs: number | null = null;
  let databaseOk = false;

  if (isSupabaseConfigured) {
    const started = performance.now();
    try {
      const supabase = await createSupabaseServerClient();
      // The cheapest possible round trip: a head count against a tiny table,
      // no rows returned. RLS applies, and an anonymous caller seeing nothing
      // is fine — this measures the trip, not the contents.
      const { error } = await supabase
        .from('permissions')
        .select('code', { count: 'exact', head: true });
      databaseOk = !error;
    } catch {
      databaseOk = false;
    }
    databaseMs = Math.round(performance.now() - started);
  }

  return NextResponse.json({
    status: 'ok',
    configured: isSupabaseConfigured,
    database: { reachable: databaseOk, roundTripMs: databaseMs },
    version: '1.0.0',
    timestamp: new Date().toISOString(),
  });
}
