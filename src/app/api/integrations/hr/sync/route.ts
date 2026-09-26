import { NextResponse } from 'next/server';
import { timingSafeEqual } from 'node:crypto';

import { serverEnv } from '@/config/env';
import { syncFromHr } from '@/server/services/hr/hr-sync-service';

export const dynamic = 'force-dynamic';

/**
 * A scheduler's way to run the HR sync (a Railway cron, say every 15 minutes).
 * Refused unless HR_SYNC_SECRET is set and the x-sync-secret header matches it.
 */
export async function POST(request: Request) {
  const secret = serverEnv().HR_SYNC_SECRET;
  const given = request.headers.get('x-sync-secret') ?? '';
  if (!secret || given.length !== secret.length || !timingSafeEqual(Buffer.from(given), Buffer.from(secret))) {
    return NextResponse.json({ error: 'Refused' }, { status: 401 });
  }
  const outcome = await syncFromHr();
  return NextResponse.json(outcome, { status: outcome.ok ? 200 : 502 });
}
