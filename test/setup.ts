import { afterEach, beforeEach, vi } from 'vitest';

/**
 * Two things every test in this project gets for free.
 *
 * **No real network.** `globalThis.fetch` throws. The IRP client talks to a tax
 * portal; a test that accidentally reaches it would be slow, flaky, and — with
 * the wrong credentials in scope — capable of filing something. A test that
 * needs fetch stubs it explicitly, which also makes the intent visible.
 *
 * **No ambient configuration.** A developer with GST credentials in
 * `.env.local` must not get different results from CI, and the
 * `NOT_CONFIGURED` paths are only reachable when the variables are genuinely
 * absent. Cleared before each test rather than once, because `vi.stubEnv` in
 * one test would otherwise leak into the next.
 */
const CLEARED_PREFIXES = ['GST_API_', 'ATTENDANCE_API_'];

beforeEach(() => {
  for (const key of Object.keys(process.env)) {
    if (CLEARED_PREFIXES.some((prefix) => key.startsWith(prefix))) {
      vi.stubEnv(key, '');
    }
  }

  vi.stubGlobal('fetch', () => {
    throw new Error(
      'A test tried to use the real fetch. Stub it with vi.stubGlobal("fetch", …) ' +
        'in the test that needs it.',
    );
  });
});

afterEach(() => {
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});
