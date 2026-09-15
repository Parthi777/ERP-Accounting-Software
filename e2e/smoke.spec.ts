import { expect, test } from '@playwright/test';

/**
 * What holds without a session.
 *
 * Runs anywhere, writes nothing, and covers the two things that would take the
 * whole product down: the app not booting, and the auth gate not gating.
 */

test('the app is up and reports its health honestly', async ({ request }) => {
  const response = await request.get('/api/health');
  expect(response.status()).toBe(200);

  const body = await response.json();
  expect(body.status).toBe('ok');
  // `configured` false would mean the app is serving /setup, not the product.
  expect(body.configured).toBe(true);
});

test('the database probe is opt-in and answers when asked', async ({ request }) => {
  const off = await (await request.get('/api/health')).json();
  expect(off.database.reachable).toBe(false);

  const on = await (await request.get('/api/health?db=1')).json();
  expect(on.database.reachable).toBe(true);
  expect(on.database.warmQueryMs).toBeGreaterThanOrEqual(0);
});

test('an anonymous visitor is sent to the login page, not into the app', async ({ page }) => {
  await page.goto('/dashboard');
  await expect(page).toHaveURL(/\/login/);
  await expect(page.getByLabel(/email/i)).toBeVisible();
});

/**
 * The gate is a convenience, not the security boundary — authorization is
 * decided in the service layer and enforced by RLS. But a gate that stopped
 * redirecting would put every screen one URL away from a stranger, so it is
 * checked across a spread of modules rather than one page.
 */
test('every module redirects an anonymous visitor', async ({ page }) => {
  for (const route of [
    '/accounting/journals',
    '/accounting/ledger',
    '/cash-book',
    '/customers',
    '/gst/e-way-bill',
    '/admin/users',
    '/reports/margin',
  ]) {
    await page.goto(route);
    await expect(page, `${route} should redirect`).toHaveURL(/\/login/);
  }
});

test('the login page does not leak whether an address exists', async ({ page }) => {
  await page.goto('/login');

  // Hydration is waited on by outcome rather than by probing internals. React 19
  // no longer exposes __reactProps on DOM nodes, and window.__next_r exists only
  // in dev — a production build never sets it, so a probe for either waits
  // forever against the build this suite actually runs.
  //
  // So: submit, and if the click landed before the handler was attached, the
  // browser's own POST reloads the page and the alert never appears. Retrying
  // once covers that without pretending it cannot happen.
  await page.waitForLoadState('networkidle');

  const submit = async () => {
    await page.getByLabel(/email/i).fill('nobody-here@example.invalid');
    await page.getByLabel(/password/i).fill('wrong-password');
    await page.getByRole('button', { name: /sign in/i }).click();
  };

  await submit();
  if ((await page.getByRole('alert').count()) === 0) {
    await page.waitForTimeout(1500);
    if ((await page.getByRole('alert').count()) === 0) await submit();
  }

  await expect(page).toHaveURL(/\/login/);

  const alert = page.getByRole('alert');
  await expect(alert).toBeVisible();
  // The message must not distinguish "no such user" from "wrong password":
  // that difference is an account-enumeration oracle.
  await expect(alert).not.toContainText(/no account|not found|does not exist/i);
});

/**
 * Found by this suite, and worth keeping found.
 *
 * Until React hydrates, a click on the sign-in button falls through to the
 * browser's own form submission. A form with no method GETs — which puts the
 * password into the URL, the browser history, the referrer header and every
 * access log between the user and the server. On a slow device that window is
 * real, and the credential is leaked before anything has gone wrong.
 *
 * method="post" keeps it in the request body on the one submission that escapes
 * the handler.
 */
test('a password can never reach the URL, even before hydration', async ({ page }) => {
  for (const path of ['/login', '/reset-password']) {
    await page.goto(path);
    const method = await page.locator('form').first().getAttribute('method');
    expect(method?.toLowerCase(), `${path} must not fall back to GET`).toBe('post');
  }
});
