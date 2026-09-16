import { expect, type Locator, type Page } from '@playwright/test';

/**
 * Helpers shared by the write-path specs.
 *
 * Everything here exists because a write test has two problems a read test does
 * not: it has to leave the database in a state the next run can cope with, and
 * it has to be able to find the row it just wrote among everything else.
 */

/**
 * A string unique to this run, short enough to fit a reference field.
 *
 * Every row these specs create carries it. That is what makes "exactly one
 * receipt was written" a countable assertion rather than a guess, and it is why
 * a second run does not trip over the first run's rows.
 */
export const RUN = `E2E${Date.now().toString(36).toUpperCase().slice(-6)}`;

/** Today, as the date inputs and the cash book both spell it. */
export function today(): string {
  return new Date().toISOString().slice(0, 10);
}

/**
 * Choose an option in a SearchSelect.
 *
 * The control is a combobox that filters as you type and writes the chosen id
 * into a hidden input; clicking the visible text is not enough, because the form
 * reads the hidden value. Typing and then clicking the option is the same path a
 * person takes.
 */
export async function pick(combobox: Locator, text: string): Promise<void> {
  await combobox.click();
  await combobox.fill(text);
  const option = combobox.page().getByRole('option', { name: new RegExp(escapeRe(text), 'i') }).first();
  await expect(option, `no option matching "${text}"`).toBeVisible({ timeout: 10_000 });
  await option.click();
}

function escapeRe(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/**
 * Fail the test on an app 5xx or an uncaught exception, the same way the
 * read-only suite does — a write that "succeeded" while the server 500ed is the
 * worst possible pass.
 */
export function watchForFailures(page: Page, baseURL: string | undefined): string[] {
  const failures: string[] = [];
  page.on('pageerror', (error) => failures.push(`uncaught: ${error.message}`));
  page.on('response', (response) => {
    if (response.status() >= 500 && response.url().startsWith(baseURL ?? '')) {
      failures.push(`${response.status()} ${response.url()}`);
    }
  });
  return failures;
}

/** Attach a CSV to a file input without writing a temporary file to disk. */
export async function attachCsv(input: Locator, name: string, content: string): Promise<void> {
  await input.setInputFiles({ name, mimeType: 'text/csv', buffer: Buffer.from(content, 'utf8') });
}
