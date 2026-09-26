import { describe, expect, it } from 'vitest';

import { hrSignature, verifyHrSignature } from './hr-signature';

const secret = 'a'.repeat(64);
const body = '{"id":"evt-1","type":"claim.approved","data":{"amount":450}}';
const now = 1_790_000_000;

describe('verifyHrSignature', () => {
  it('accepts the HR app\'s signature on the exact body', () => {
    const sig = hrSignature(secret, String(now), body);
    expect(verifyHrSignature(secret, String(now), sig, body, now)).toEqual({ ok: true });
  });

  it('refuses a changed body, a wrong secret, a missing or stale signature', () => {
    const sig = hrSignature(secret, String(now), body);
    expect(verifyHrSignature(secret, String(now), sig, body.replace('450', '4500'), now).ok).toBe(false);
    expect(verifyHrSignature('b'.repeat(64), String(now), sig, body, now).ok).toBe(false);
    expect(verifyHrSignature(secret, null, sig, body, now)).toEqual({ ok: false, reason: 'unsigned' });
    expect(verifyHrSignature(secret, String(now - 301), hrSignature(secret, String(now - 301), body), body, now))
      .toEqual({ ok: false, reason: 'stale' });
  });
});
