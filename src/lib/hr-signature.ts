import { createHmac, timingSafeEqual } from 'node:crypto';

/**
 * The HR app signs each webhook: `sha256=<hex HMAC-SHA256 of "<timestamp>.<body>">`
 * with the secret it showed once on connecting (HR_WEBHOOK_SECRET here). A
 * signature is accepted only for the exact bytes received and only within five
 * minutes of its timestamp, so a captured request cannot be replayed later.
 */
export const HR_SIGNATURE_WINDOW_SECONDS = 300;

export function hrSignature(secret: string, timestamp: string, body: string): string {
  return `sha256=${createHmac('sha256', secret).update(`${timestamp}.${body}`).digest('hex')}`;
}

export type SignatureCheck = { ok: true } | { ok: false; reason: string };

export function verifyHrSignature(
  secret: string,
  timestamp: string | null,
  signature: string | null,
  body: string,
  nowSeconds: number = Math.floor(Date.now() / 1000),
): SignatureCheck {
  if (!timestamp || !signature) return { ok: false, reason: 'unsigned' };
  const ts = Number(timestamp);
  if (!Number.isInteger(ts)) return { ok: false, reason: 'bad timestamp' };
  if (Math.abs(nowSeconds - ts) > HR_SIGNATURE_WINDOW_SECONDS) return { ok: false, reason: 'stale' };
  const expected = Buffer.from(hrSignature(secret, timestamp, body));
  const given = Buffer.from(signature);
  if (expected.length !== given.length || !timingSafeEqual(expected, given)) return { ok: false, reason: 'bad signature' };
  return { ok: true };
}
