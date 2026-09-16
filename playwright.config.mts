import { join } from 'node:path';

import { defineConfig, devices } from '@playwright/test';

// `.mts`, not `.ts`: Playwright loads a .ts config as CommonJS unless
// package.json says "type": "module", which this package cannot say without
// changing how Next treats every other file. Same reason as vitest.config.mts.
const here = process.cwd();

/**
 * End-to-end tests.
 *
 * Everything else in this project is verified below the browser: 860 SQL
 * assertions on the database and 105 Vitest assertions on the TypeScript. What
 * neither can see is whether a page actually renders — a server component that
 * throws, a prop that arrives undefined, a query that fails only under a real
 * session. That is the gap these close.
 *
 * ── Against which database ──────────────────────────────────────────────────
 *
 * There is no local Supabase here (no Docker, no CLI), so the app under test
 * talks to whatever .env.local points at. The suite is therefore split:
 *
 *   smoke      no session, no writes — safe anywhere
 *   authed     needs E2E_EMAIL / E2E_PASSWORD; navigates every route read-only
 *   flows      writes; refuses to run unless E2E_ALLOW_WRITES=1
 *
 * A bare `npx playwright test` runs all three, but `flows` skips every test
 * unless E2E_ALLOW_WRITES=1 — so the default run reads and never writes, and
 * still reports that a write suite exists rather than hiding it. The gate is the
 * variable, not the project name.
 *
 * That gate is deliberate: some of what `flows` does cannot be undone. A posted
 * journal is immutable (spec §23), and a dealer that has posted journals can
 * only be closed, never purged. It belongs against a throwaway tenant and
 * nowhere else.
 */
export default defineConfig({
  testDir: join(here, 'e2e'),
  // One worker: the app under test is a single dev server against one database,
  // and parallel navigation would make a failure hard to attribute.
  workers: 1,
  fullyParallel: false,
  reporter: [['list']],

  /**
   * One retry.
   *
   * These screens are server-rendered against a Supabase instance in another
   * region, and the suite opens eighty of them in sequence. A page that takes
   * four seconds normally occasionally takes twenty, and without a retry the
   * run reports a different two or three "failures" every time — which trains
   * everyone to ignore the result, the worst outcome for a test suite.
   *
   * A failure that survives a retry is worth looking at. The inventory report
   * 500 did.
   */
  retries: 1,

  projects: [
    // No session: runs anywhere, writes nothing.
    { name: 'smoke', testMatch: /smoke\.spec\.ts/ },

    // Signs in once; the rest reuse the stored session.
    { name: 'setup', testMatch: /auth\.setup\.ts/ },
    {
      name: 'authed',
      testMatch: /screens\.spec\.ts/,
      dependencies: ['setup'],
      use: { storageState: 'test-results/.auth/session.json' },
    },

    // Writes. Runs only with the flag:
    //   E2E_ALLOW_WRITES=1 npx playwright test --project=flows
    // Without it every test in the project skips, so a run that forgets the
    // flag reports skipped rather than quietly writing to whatever .env.local
    // happens to point at.
    {
      name: 'flows',
      testMatch: /flows\.spec\.ts/,
      dependencies: ['setup'],
      use: { storageState: 'test-results/.auth/session.json' },
    },
  ],
  timeout: 60_000,
  expect: { timeout: 15_000 },

  use: {
    baseURL: process.env.E2E_BASE_URL ?? 'http://127.0.0.1:3100',
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    // A dealer works on a desktop (spec §8: desktop-first).
    ...devices['Desktop Chrome'],
    viewport: { width: 1440, height: 900 },
  },

  // A production build, not `next dev`. Dev recompiles and invalidates chunks as
  // files change, and a chunk that fails to load leaves the page rendered but
  // inert — which looks exactly like a broken feature and is not one. This is
  // also what Railway serves, so a pass here says something about production.
  webServer: process.env.E2E_BASE_URL
    ? undefined
    : {
        command: 'npm run build && npm run start -- --port 3100',
        url: 'http://127.0.0.1:3100/api/health',
        // Never reuse: a server left over from an earlier build would be testing
        // code that is no longer on disk.
        reuseExistingServer: false,
        timeout: 420_000,
      },
});
