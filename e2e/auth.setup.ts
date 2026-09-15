import { expect, test as setup } from '@playwright/test';

/**
 * Signs in once and saves the session for every other authenticated spec.
 *
 * Credentials come from the environment, never from the repository. Playwright
 * writes the storage state to a file that .gitignore excludes — it contains a
 * live Supabase JWT, which is a bearer token for that user until it expires.
 */
export const STORAGE_STATE = 'test-results/.auth/session.json';

setup('sign in', async ({ page }) => {
  const email = process.env.E2E_EMAIL;
  const password = process.env.E2E_PASSWORD;

  if (!email || !password) {
    throw new Error(
      'E2E_EMAIL and E2E_PASSWORD are required for the authenticated suite.\n' +
        'Run: E2E_EMAIL=you@example.com E2E_PASSWORD=… npx playwright test',
    );
  }

  await page.goto('/login');
  await page.waitForLoadState('networkidle');

  const submit = async () => {
    await page.getByLabel(/email/i).fill(email);
    await page.getByLabel(/password/i).fill(password);
    await page.getByRole('button', { name: /sign in/i }).click();
  };

  // The same pre-hydration retry the smoke suite explains.
  await submit();
  await page.waitForTimeout(1500);
  if (page.url().includes('/login')) {
    await page.waitForTimeout(1500);
    if (page.url().includes('/login')) await submit();
  }

  await expect(page, 'sign-in should leave the login page').not.toHaveURL(/\/login/);
  await page.context().storageState({ path: STORAGE_STATE });
});
