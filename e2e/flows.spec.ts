import { expect, test } from '@playwright/test';

import { RUN, assertWritableTenant, attachCsv, pick, today, watchForFailures } from './writes';

/**
 * The write paths, driven through a browser.
 *
 * Everything else in this project proves the database is right: 870 SQL
 * assertions on the functions, 105 Vitest assertions on the pure TypeScript, and
 * a read-only browser sweep of all 81 screens. None of them submits a form. So
 * the layer that has never been exercised is precisely the one a dealer touches
 * — a server action wired to the wrong argument, a picker whose hidden input
 * never gets written, a confirm button that stays disabled.
 *
 * ── These tests write. Read this before pointing them anywhere ──────────────
 *
 * They are skipped unless E2E_ALLOW_WRITES=1, and they refuse to run unless
 * E2E_WRITE_DEALER names the tenant the app is actually signed into. Some of
 * what they do cannot be undone: a posted journal is immutable by design
 * (spec §23), and a dealer that has posted journals cannot be purged, only
 * closed. Running this against a real dealer leaves permanent rows in their
 * ledger.
 *
 * The check is mechanical rather than advisory because the default points the
 * wrong way: with E2E_BASE_URL unset, Playwright builds and starts the app from
 * .env.local, which in this repo is production. See docs/testing-staging.md.
 *
 * Every row carries RUN, a per-run tag, so a second run neither collides with
 * the first nor has to guess which rows are its own.
 */

const WRITES_ENABLED = process.env.E2E_ALLOW_WRITES === '1';

test.describe('write paths', () => {
  test.skip(
    !WRITES_ENABLED,
    'Writes are opt-in. Set E2E_ALLOW_WRITES=1, and only against a throwaway tenant.',
  );

  // Before anything writes: confirm this is the tenant we were told to write
  // into. The comment above is advice; this is the guard.
  test.beforeAll(async ({ browser }) => {
    const page = await browser.newPage();
    try {
      await assertWritableTenant(page);
    } finally {
      await page.close();
    }
  });

  // Serial: these share one tenant and one cash day, and a failure part-way
  // through leaves state the later tests would misread. Attributing a cascade of
  // failures to the first one is also far easier than to a parallel interleave.
  test.describe.configure({ mode: 'serial' });

  // ---------------------------------------------------------------------------
  // Customers — the simplest write there is, and the one every later flow needs
  // ---------------------------------------------------------------------------
  test('create a customer', async ({ page, baseURL }) => {
    const failures = watchForFailures(page, baseURL);
    const name = `Test Customer ${RUN}`;

    await page.goto('/customers/new');
    await page.getByLabel(/^name/i).fill(name);
    await page.getByLabel(/^mobile/i).fill(mobileFor(RUN));
    await page.getByRole('button', { name: /save|create/i }).first().click();

    // A customer id is issued by the database, so landing on the detail page is
    // itself the assertion that the insert and its trigger both ran.
    await expect(page, 'should land on the new customer').toHaveURL(/\/customers\/[0-9a-f-]{36}/, {
      timeout: 30_000,
    });
    await expect(page.getByText(name).first()).toBeVisible();
    expect(failures).toEqual([]);
  });

  // ---------------------------------------------------------------------------
  // CSV import — spec §14: preview, validate, error report, confirm. Never a
  // partial import. This is the path the first real dealer's data arrives on.
  // ---------------------------------------------------------------------------
  test('a CSV with a bad row blocks the import entirely', async ({ page, baseURL }) => {
    const failures = watchForFailures(page, baseURL);

    await page.goto('/customers/upload');
    await attachCsv(
      page.locator('input[type="file"]'),
      'bad.csv',
      [
        'name,mobile,city',
        `Good Row ${RUN},${mobileFor(RUN + 'a')},Coimbatore`,
        // No mobile: the row the importer must reject.
        `Bad Row ${RUN},,Coimbatore`,
      ].join('\n'),
    );

    await expect(page.getByText(/row\(s\) with errors/i)).toBeVisible({ timeout: 30_000 });

    // The rule that matters is not that it warns — it is that confirming is
    // impossible while any row is bad, so the file goes in whole or not at all.
    await expect(
      page.getByRole('button', { name: /confirm import/i }),
      'confirm must be disabled while a row has errors',
    ).toBeDisabled();

    expect(failures).toEqual([]);
  });

  test('import customers from a CSV', async ({ page, baseURL }) => {
    const failures = watchForFailures(page, baseURL);
    const rows = 5;

    await page.goto('/customers/upload');
    await attachCsv(
      page.locator('input[type="file"]'),
      'customers.csv',
      [
        'name,mobile,city,state,state_code',
        ...Array.from(
          { length: rows },
          (_, i) => `Imported ${RUN} ${i + 1},${mobileFor(`${RUN}${i}`)},Coimbatore,Tamil Nadu,33`,
        ),
      ].join('\n'),
    );

    await expect(page.getByText(/ready to import/i)).toBeVisible({ timeout: 30_000 });
    await page.getByRole('button', { name: /confirm import/i }).click();

    await expect(
      page.getByRole('heading', { name: new RegExp(`${rows} customers imported`, 'i') }),
      'the importer should report exactly what it wrote',
    ).toBeVisible({ timeout: 60_000 });

    // And they must be findable, not merely reported — a count from the importer
    // is the importer marking its own homework.
    await page.goto(`/customers?q=${encodeURIComponent(`Imported ${RUN}`)}`);
    await expect(page.getByText(new RegExp(`Imported ${RUN} 1`))).toBeVisible({ timeout: 30_000 });
    expect(failures).toEqual([]);
  });

  // ---------------------------------------------------------------------------
  // Double entry, immutability and reversal — spec §22, §23
  // ---------------------------------------------------------------------------
  test('post a manual journal, then reverse it', async ({ page, baseURL }) => {
    const failures = watchForFailures(page, baseURL);
    const narration = `Bank charges ${RUN}`;

    await page.goto('/accounting/journals/new');
    await page.getByLabel(/narration/i).fill(narration);

    const comboboxes = page.getByRole('combobox');
    await pick(comboboxes.nth(0), 'Bank Charges');
    await pick(comboboxes.nth(1), 'Other Payables');

    const debits = page.locator('input[type="number"]');
    await debits.nth(0).fill('250');
    await debits.nth(3).fill('250');

    // The form says so itself before it will let the entry be posted, which is
    // the double-entry rule surfaced in the UI rather than only in the trigger.
    await expect(page.getByText(/^Balanced$/)).toBeVisible();

    await page.getByRole('button', { name: /post entry/i }).click();
    await expect(page, 'should land on the posted entry').toHaveURL(/\/accounting\/journals\/[0-9a-f-]{36}/, {
      timeout: 30_000,
    });
    await expect(page.getByText(narration).first()).toBeVisible();

    // A posted entry cannot be edited (spec §23) — the only correction is a
    // reversal, and it must ask for a reason.
    await expect(page.getByRole('button', { name: /^edit$/i })).toHaveCount(0);

    await page.getByRole('button', { name: /^reverse$/i }).click();
    await page.getByLabel(/reason/i).fill(`Written by the e2e suite, run ${RUN}`);
    await page.getByRole('button', { name: /reverse entry/i }).click();

    await expect(
      page.getByText(/reversed/i).first(),
      'the entry should show as reversed once the reversal posts',
    ).toBeVisible({ timeout: 30_000 });
    expect(failures).toEqual([]);
  });

  // ---------------------------------------------------------------------------
  // Idempotency — spec §50
  // ---------------------------------------------------------------------------
  test('a double-clicked cash receipt writes one row', async ({ page, baseURL }) => {
    const failures = watchForFailures(page, baseURL);
    const reference = `${RUN}-DBL`;

    await page.goto(`/cash-book/receipts?date=${today()}`);

    // The day may already be closed by an earlier run on the same date. That is
    // correct behaviour, not a failure, and there is nothing to test past it.
    if (await page.getByText(/day is closed|closed for/i).first().isVisible().catch(() => false)) {
      test.skip(true, 'the cash day is already closed; re-run tomorrow or reopen it');
    }

    await page.getByLabel(/amount/i).fill('500');
    await page.getByLabel(/reference/i).fill(reference);
    await page.getByLabel(/particular/i).fill(`Double-submit probe ${RUN}`);
    await pick(page.getByRole('combobox').first(), 'Other Income');

    // Two clicks as fast as Playwright can dispatch them, with no wait between.
    //
    // What this proves depends on which guard catches it, and both are worth
    // having: React disables the button once the transition starts, and behind
    // that the RPC carries an idempotency key so a retry replays instead of
    // inserting. A network-timeout retry — the case the key really exists for —
    // cannot be staged from a click, and is covered by 9L in SQL. This covers
    // the case a cashier actually produces.
    const submit = page.getByRole('button', { name: /save|record|receipt/i }).last();
    await Promise.all([submit.click(), submit.click({ force: true }).catch(() => {})]);

    await page.waitForLoadState('networkidle');

    // Count in the cash book, not in the form's own response.
    await page.goto(`/cash-book?date=${today()}`);
    await expect(page.getByText(reference).first()).toBeVisible({ timeout: 30_000 });
    await expect(
      page.getByText(reference),
      'a double-clicked receipt must appear exactly once in the cash book',
    ).toHaveCount(1);

    expect(failures).toEqual([]);
  });

  // ---------------------------------------------------------------------------
  // Day close — spec §36. Runs last: it shuts the day the tests above wrote to.
  // ---------------------------------------------------------------------------
  test('close the cash day', async ({ page, baseURL }) => {
    const failures = watchForFailures(page, baseURL);

    await page.goto(`/cash-book/day-close?date=${today()}`);

    if (await page.getByRole('button', { name: /reopen/i }).first().isVisible().catch(() => false)) {
      test.skip(true, 'the day is already closed — a re-run on the same date has nothing to close');
    }

    const expected = page.getByText(/expected closing/i).first();
    await expect(expected).toBeVisible({ timeout: 30_000 });

    // Count the cash as exactly what the book expects, so the close needs no
    // difference explanation. Counting *wrong* is a different test, and it wants
    // its own tenant state rather than being bolted on here.
    const physical = page.getByLabel(/physical|counted/i).first();
    await physical.fill(await expectedClosing(page));
    await page.getByRole('button', { name: /close the day|close day/i }).last().click();

    await expect(
      page.getByText(/closed/i).first(),
      'the day should report itself closed',
    ).toBeVisible({ timeout: 30_000 });
    expect(failures).toEqual([]);
  });
});

/**
 * A mobile number derived from the run tag.
 *
 * Customers are unique on mobile, so a fixed number would pass once and then
 * collide with itself forever.
 */
function mobileFor(seed: string): string {
  let hash = 0;
  for (const ch of seed) hash = (hash * 31 + ch.charCodeAt(0)) % 1_000_000_000;
  return `9${String(hash).padStart(9, '0')}`.slice(0, 10);
}

/** The expected closing figure the page is showing, as a plain number. */
async function expectedClosing(page: import('@playwright/test').Page): Promise<string> {
  const text = await page.getByText(/expected closing/i).first().locator('..').innerText();
  const match = /([\d,]+\.\d{2})/.exec(text);
  return (match?.[1] ?? '0').replace(/,/g, '');
}
