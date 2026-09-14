'use client';

import * as React from 'react';

import { newIdempotencyKey } from '@/lib/idempotency';

/**
 * Holds one idempotency key for a form, and renews it once the server has taken
 * the submission (spec §50).
 *
 * ── Why sessionStorage and not useState ─────────────────────────────────────
 *
 * `React.useState(() => crypto.randomUUID())` — the shape this replaces —
 * survives a double-click and a `startTransition` retry, because the component
 * stays mounted. It does not survive a page refresh. Someone who submits, sees a
 * spinner, loses patience and presses F5 gets a fresh key and posts the same
 * receipt twice, which is one of the exact cases idempotency exists to stop.
 *
 * sessionStorage rather than localStorage: the key should die with the tab. A
 * key that outlived the browser would block a legitimate identical entry the
 * next morning — the same customer, the same ₹500, a genuinely new receipt.
 *
 * ── Why a getter and not a value ────────────────────────────────────────────
 *
 * A `useState` initializer in a client component still runs during server
 * rendering, where `sessionStorage` does not exist. The key is filled lazily
 * inside `key()` at submit time instead, so the server never runs the mint. It
 * is never rendered either, so there is no hydration mismatch to have.
 *
 * @param scope Identifies the form *and* what it is acting on, so two tabs
 *   editing different records do not share a key. Include the entity id:
 *   `useIdempotencyKey(\`sale-payment:\${saleId}\`)`.
 */
export function useIdempotencyKey(scope: string): {
  /** The current key, minted on first use. Call at submit time. */
  key: () => string;
  /** Call after a confirmed success, so the next entry is its own. */
  renew: () => void;
} {
  const storageKey = `idem:${scope}`;
  const cached = React.useRef<string | null>(null);

  // sessionStorage throws in some privacy modes rather than returning null, so
  // every access is guarded. A browser that refuses storage still gets working
  // idempotency for the mounted lifetime of the form, via the ref — strictly
  // less protection, and better than a form that will not submit.
  const read = (): string | null => {
    try {
      return window.sessionStorage.getItem(storageKey);
    } catch {
      return null;
    }
  };

  const write = (value: string): void => {
    try {
      window.sessionStorage.setItem(storageKey, value);
    } catch {
      /* ignore — the ref still carries it for this mount */
    }
  };

  const key = React.useCallback((): string => {
    if (cached.current) return cached.current;

    const stored = read();
    if (stored) {
      cached.current = stored;
      return stored;
    }

    const minted = newIdempotencyKey();
    cached.current = minted;
    write(minted);
    return minted;
    // `storageKey` is the only input, and it is derived from `scope`.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [storageKey]);

  const renew = React.useCallback((): void => {
    cached.current = null;
    try {
      window.sessionStorage.removeItem(storageKey);
    } catch {
      /* ignore */
    }
  }, [storageKey]);

  return { key, renew };
}
