import type { Metadata } from 'next';

import { requireTenantContext } from '@/server/auth/tenant-context';
import {
  getAccountLedger,
  getPostableAccounts,
} from '@/server/services/accounting/journal-entry-service';
import { AccountLedgerView } from '@/components/accounting/account-ledger-view';
import { SearchSelect } from '@/components/forms/search-select';
import { PageHeader } from '@/components/data-table/data-table';
import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { rangeInYear } from '@/lib/period';

export const metadata: Metadata = { title: 'Account ledger' };
export const dynamic = 'force-dynamic';

/**
 * The ledger of any account in the chart — spec §41, §43.
 *
 * The plainest report there is, and the one the product never had: the trial
 * balance gives a total and stops, so "why is Bank Charges 4,150" had nowhere
 * to be answered. Entries can be added from here without leaving the page,
 * because someone who notices something missing is already looking at the
 * account it belongs to.
 */
export default async function AccountLedgerPage({
  searchParams,
}: {
  searchParams: Promise<{ account?: string; code?: string; from?: string; to?: string }>;
}) {
  const context = await requireTenantContext();
  const params = await searchParams;

  const range = rangeInYear(context.activeFinancialYear, params.from, params.to);
  const accounts = await getPostableAccounts();

  // `code` as well as `account`, so the trial balance and any other screen
  // holding a code rather than an id can link straight through — and so a URL
  // someone pastes to a colleague says which account it is.
  const selected =
    params.account ?? (params.code ? (accounts.find((a) => a.code === params.code)?.id ?? '') : '');

  const ledger = selected
    ? await getAccountLedger({ accountId: selected, from: range.from, to: range.to })
    : null;

  return (
    <>
      <PageHeader
        title="Account ledger"
        description="What moved through one account, and what sat on the other side of each entry (spec §41)."
      />

      <Panel className="mb-4 p-4">
        <form method="get" className="flex flex-wrap items-end gap-3" action="/accounting/ledger">
          <div className="min-w-72 flex-1">
            <label htmlFor="account" className="mb-1.5 block text-xs font-medium text-ink-600">
              Account
            </label>
            <SearchSelect
              id="account"
              name="account"
              options={accounts.map((a) => ({ id: a.id, label: `${a.code} · ${a.name}` }))}
              defaultValue={selected}
              placeholder="Search the chart of accounts by code or name…"
              submitOnSelect
            />
          </div>
          <div>
            <label htmlFor="from" className="mb-1.5 block text-xs font-medium text-ink-600">From</label>
            <input
              id="from" type="date" name="from" defaultValue={range.from}
              className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
            />
          </div>
          <div>
            <label htmlFor="to" className="mb-1.5 block text-xs font-medium text-ink-600">To</label>
            <input
              id="to" type="date" name="to" defaultValue={range.to}
              className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
            />
          </div>
          <Button type="submit" variant="secondary">Show ledger</Button>
        </form>
      </Panel>

      {!ledger && (
        <Panel className="p-10 text-center text-sm text-ink-500">
          Choose an account to see what moved through it.
        </Panel>
      )}

      {ledger && (
        <AccountLedgerView
          ledger={ledger}
          accounts={accounts}
          canPost={context.permissions.has('accounting.journals.post')}
        />
      )}
    </>
  );
}
