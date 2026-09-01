import { NextResponse } from 'next/server';

import { isSupabaseConfigured } from '@/config/env';

export const dynamic = 'force-dynamic';

/**
 * Railway health check (see railway.json).
 *
 * Returns 200 even when Supabase is unconfigured, so a first deploy passes its
 * health check and serves /setup rather than crash-looping before anyone can add
 * the environment variables. `configured: false` makes the state visible.
 */
export async function GET() {
  return NextResponse.json({
    status: 'ok',
    configured: isSupabaseConfigured,
    version: '1.0.0',
    timestamp: new Date().toISOString(),
  });
}
