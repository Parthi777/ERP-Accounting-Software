/**
 * Keys that make a retried financial submission replay rather than repeat
 * (spec §50).
 *
 * The key identifies an *intent* — "this receipt, the one the cashier is filling
 * in now" — so it is minted in the browser when the form is opened, travels with
 * the submission, and is renewed only once the server has confirmed the write.
 * A server-minted key could not do this: by the time the request arrives, the
 * server cannot tell a retry from a second genuine entry, which is the whole
 * question.
 *
 * Only for *creating* a document. Posting one that already exists derives its
 * key from the document id in the database (`'sale:' || id`), which is stronger
 * — it dedupes across sessions and devices, not just within one tab.
 */

/**
 * A fresh key.
 *
 * `crypto.randomUUID()` alone is not enough. It exists only in a secure context:
 * https, or localhost. A dealer reaching this app over plain http on a shop LAN
 * — which is exactly how a counter PC talks to a machine in the back office —
 * gets `crypto.randomUUID is not a function`, and the form dies on submit with a
 * TypeError. `getRandomValues` has no such restriction, so it carries the
 * fallback.
 */
export function newIdempotencyKey(): string {
  if (typeof crypto !== 'undefined' && typeof crypto.randomUUID === 'function') {
    return crypto.randomUUID();
  }

  if (typeof crypto !== 'undefined' && typeof crypto.getRandomValues === 'function') {
    const bytes = crypto.getRandomValues(new Uint8Array(16));
    // RFC 4122 version 4, variant 10xx — not because anything parses it, but so
    // a key in a log or a database column reads as the UUID it claims to be.
    bytes[6] = (bytes[6]! & 0x0f) | 0x40;
    bytes[8] = (bytes[8]! & 0x3f) | 0x80;
    const hex = [...bytes].map((b) => b.toString(16).padStart(2, '0')).join('');
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  }

  // No Web Crypto at all. Not reachable from a browser this application supports,
  // but a key is the difference between one receipt and two: refuse rather than
  // fall back to Math.random(), whose collisions would silently merge two
  // genuine receipts into one.
  throw new Error('This browser cannot generate a secure key, so the form cannot be submitted safely.');
}
