import { NextResponse } from 'next/server';

import { serverEnv } from '@/config/env';
import { createSupabaseAdminClient } from '@/lib/supabase/server';
import { verifyHrSignature } from '@/lib/hr-signature';
import { hrDealerId } from '@/server/services/hr/hr-sync-service';

export const dynamic = 'force-dynamic';

/**
 * The HR Payroll app announcing a claim decision (0095).
 *
 * No session: the request proves itself with an HMAC signature over the exact
 * bytes, made with the secret the HR app showed once on connecting, and a
 * timestamp no older than five minutes. The event id is recorded, so a replay
 * — the HR app retries until it gets a 2xx — is answered without doing anything
 * twice. A database failure answers 500, which the HR app retries.
 */
export async function POST(request: Request) {
  const secret = serverEnv().HR_WEBHOOK_SECRET;
  if (!secret) {
    return NextResponse.json({ error: 'The HR connection is not configured here.' }, { status: 503 });
  }

  const body = await request.text();
  const check = verifyHrSignature(secret, request.headers.get('x-hr-timestamp'), request.headers.get('x-hr-signature'), body);
  if (!check.ok) {
    return NextResponse.json({ error: `Refused: ${check.reason}` }, { status: 401 });
  }

  let event: { id?: string; type?: string; data?: unknown };
  try {
    event = JSON.parse(body);
  } catch {
    return NextResponse.json({ error: 'Not JSON' }, { status: 400 });
  }
  if (!event.id || !event.type) {
    return NextResponse.json({ error: 'An event needs an id and a type' }, { status: 400 });
  }

  const dealerId = await hrDealerId();
  if (!dealerId) {
    return NextResponse.json({ error: 'HR_DEALER_CODE does not name a dealer here.' }, { status: 503 });
  }

  const admin = createSupabaseAdminClient();
  const { data, error } = await admin.rpc('hr_receive_event', {
    p_dealer_id: dealerId,
    p_event_id: event.id,
    p_type: event.type,
    p_data: (event.data ?? {}) as never,
  });
  if (error) {
    console.error('[hr webhook] could not record the event', event.type, error.message);
    await admin.rpc('hr_record_sync_error', { p_dealer_id: dealerId, p_error: `${event.type}: ${error.message}` });
    return NextResponse.json({ error: 'Not recorded; please retry.' }, { status: 500 });
  }
  return NextResponse.json({ outcome: data });
}
