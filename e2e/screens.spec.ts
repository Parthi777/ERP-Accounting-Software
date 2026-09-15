import { expect, test } from '@playwright/test';

import { navigableRoutes } from './routes';

/**
 * Every screen the sidebar offers, opened under a real session.
 *
 * This is the coverage nothing else in the project has. The SQL suite proves the
 * database is right and Vitest proves the pure functions are; neither can see a
 * server component that throws on a null, a query that fails only under RLS, or
 * a page that renders an error boundary instead of itself.
 *
 * Read-only by design: it navigates and asserts, and submits nothing. Pointing
 * it at a live database is therefore safe, which matters because there is no
 * local Supabase to point it at instead.
 */

const routes = navigableRoutes();

test.describe('every screen renders', () => {
  for (const route of routes) {
    test(route, async ({ page, baseURL }) => {
      const failures: string[] = [];
      page.on('pageerror', (error) => failures.push(`uncaught: ${error.message}`));
      page.on('response', (response) => {
        // A 5xx from the app itself is a failure even when the shell renders
        // around it. Matched on the base URL rather than page.url(), which is
        // empty before the first navigation and made this listener compare
        // against a placeholder.
        if (response.status() >= 500 && response.url().startsWith(baseURL ?? '')) {
          failures.push(`${response.status()} ${response.url()}`);
        }
      });

      const response = await page.goto(route, { waitUntil: 'domcontentloaded' });

      // Not redirected to login: that would mean the session was rejected, and
      // every later assertion would be about the login page instead.
      expect(page.url(), `${route} bounced to login`).not.toMatch(/\/login/);
      expect(response?.status() ?? 0, `${route} returned ${response?.status()}`).toBeLessThan(400);

      // Next renders error.tsx in place of the page when a server component
      // throws. The shell still looks fine, so the text is the only signal.
      //
      // Matched against this app's own boundary copy rather than a guess. An
      // earlier version also matched a bare "500", which failed twelve screens
      // that simply displayed the number — a price, a quantity, a PIN code.
      const body = await page.locator('body').innerText();
      expect(body, `${route} rendered an error boundary`).not.toMatch(
        /Something went wrong|Application error: a client-side exception|Unhandled Runtime Error|Internal Server Error/i,
      );

      // A heading means the page reached its own render rather than a blank
      // shell — an empty database is fine, an empty document is not.
      //
      // Given its own generous timeout: these are server components querying a
      // database in another region, and several seconds is normal rather than a
      // symptom. Too tight a wait here produced a different set of "failures"
      // on every run, which is worse than no assertion at all.
      await expect(page.locator('h1, h2').first(), `${route} rendered nothing`)
        .toBeVisible({ timeout: 30_000 });

      expect(failures, `${route} raised errors`).toEqual([]);
    });
  }
});
