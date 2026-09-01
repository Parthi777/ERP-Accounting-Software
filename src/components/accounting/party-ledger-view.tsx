import Link from 'next/link';

import type {
  PartyLedger,
  LedgerPartyOption,
  LedgerLine,
} from '@/server/services/accounting/ledger-service';
import { DataTable, type Column } from '@/components/data-table/data-table';
import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { formatINR, negate, type Paise } from '@/lib/money';
import { formatDate } from '@/lib/format';

/**
 * A party's running account, rendered identically wherever it is reached —
 * spec §11, §41.
 *
 * Three routes mount this: Customers and Accounting for the customer ledger,
 * Accounting again for the supplier one. They carry different permissions, so
 * they cannot redirect to each other — but there is one implementation of the
 * statement, so they can never disagree about what a party owes.
 *
 * Everything party-specific arrives as a prop. The arithmetic does not change:
 * the ledger is debit-positive for both, and only the labels invert.
 */
export interface PartyLedgerLabels {
  /** "Customer" / "Supplier" — used for the picker label and empty states. */
  readonly party: string;
  /** What a positive (debit) closing balance means in plain words. */
  readonly debitMeaning: string;
  /** What a negative (credit) closing balance means. */
  readonly creditMeaning: string;
}

export const CUSTOMER_LEDGER_LABELS: PartyLedgerLabels = {
  party: 'Customer',
  debitMeaning: 'Receivable from the customer',
  creditMeaning: 'Held in advance for the customer',
};

export const SUPPLIER_LEDGER_LABELS: PartyLedgerLabels = {
  party: 'Supplier',
  // The mirror of a customer: the dealer owes a supplier, so the sign that reads
  // as "owed to us" for a customer reads as "paid ahead" here.
  debitMeaning: 'Paid ahead of what is billed',
  creditMeaning: 'Payable to the supplier',
};

export function PartyLedgerView({
  basePath,
  paramName,
  ledger,
  options,
  selectedId,
  from,
  to,
  labels,
  detailHref,
}: {
  /** The route this is mounted at, so the filter form posts back to itself. */
  readonly basePath: string;
  /** The query parameter carrying the selected party id. */
  readonly paramName: string;
  readonly ledger: PartyLedger | null;
  readonly options: readonly LedgerPartyOption[];
  readonly selectedId: string;
  readonly from: string;
  readonly to: string;
  readonly labels: PartyLedgerLabels;
  /** Where "Open …" links to, or null when the party has no detail page. */
  readonly detailHref?: ((ledger: PartyLedger) => string) | null;
}) {
  const lower = labels.party.toLowerCase();

  const columns: Column<LedgerLine>[] = [
    { key: 'date', header: 'Date', render: (row) => formatDate(row.date) },
    {
      key: 'entry',
      header: 'Entry',
      render: (row) => <span className="font-mono text-xs text-ink-600">{row.entryNumber}</span>,
    },
    {
      key: 'narration',
      header: 'Particulars',
      render: (row) =>
        row.narration ? (
          <span className="block max-w-md text-ink-700">{row.narration}</span>
        ) : (
          <span className="text-ink-300">—</span>
        ),
    },
    {
      key: 'debit',
      header: 'Debit',
      numeric: true,
      render: (row) => (row.debit > 0 ? formatINR(row.debit) : <span className="text-ink-300">—</span>),
    },
    {
      key: 'credit',
      header: 'Credit',
      numeric: true,
      render: (row) => (row.credit > 0 ? formatINR(row.credit) : <span className="text-ink-300">—</span>),
    },
    {
      key: 'balance',
      header: 'Balance',
      numeric: true,
      render: (row) => <span className="font-medium text-ink-800">{formatBalance(row.balance)}</span>,
    },
  ];

  return (
    <>
      <Panel className="mb-4 p-4">
        <form method="get" className="flex flex-wrap items-end gap-3" action={basePath}>
          <div className="min-w-64 flex-1">
            <label htmlFor={paramName} className="mb-1.5 block text-xs font-medium text-ink-600">
              {labels.party}
            </label>
            <select
              id={paramName}
              name={paramName}
              defaultValue={selectedId}
              className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
            >
              <option value="">Choose a {lower}</option>
              {options.map((o) => (
                <option key={o.id} value={o.id}>{o.label}</option>
              ))}
            </select>
          </div>
          <div>
            <label htmlFor="from" className="mb-1.5 block text-xs font-medium text-ink-600">From</label>
            <input
              id="from" name="from" type="date" defaultValue={from}
              className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
            />
          </div>
          <div>
            <label htmlFor="to" className="mb-1.5 block text-xs font-medium text-ink-600">To</label>
            <input
              id="to" name="to" type="date" defaultValue={to}
              className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
            />
          </div>
          <Button type="submit" variant="secondary" size="sm">Show ledger</Button>
        </form>
      </Panel>

      {!ledger ? (
        <Panel className="p-8 text-center">
          <p className="text-sm text-ink-600">
            {selectedId
              ? `That ${lower} could not be found.`
              : `Choose a ${lower} to see their running account.`}
          </p>
        </Panel>
      ) : (
        <>
          <div className="mb-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <Panel className="p-4">
              <p className="text-xs text-ink-500">Opening balance</p>
              <p className="mt-0.5 text-lg font-semibold text-ink-800">
                {formatBalance(ledger.opening)}
              </p>
            </Panel>
            <Panel className="p-4">
              <p className="text-xs text-ink-500">Debit in period</p>
              <p className="mt-0.5 text-lg font-semibold text-ink-800">{formatINR(ledger.totalDebit)}</p>
            </Panel>
            <Panel className="p-4">
              <p className="text-xs text-ink-500">Credit in period</p>
              <p className="mt-0.5 text-lg font-semibold text-ink-800">{formatINR(ledger.totalCredit)}</p>
            </Panel>
            <Panel className="p-4">
              <p className="text-xs text-ink-500">Closing balance</p>
              <p
                className={
                  ledger.closing > 0
                    ? 'mt-0.5 text-lg font-semibold text-danger-700'
                    : 'mt-0.5 text-lg font-semibold text-positive-700'
                }
              >
                {formatBalance(ledger.closing)}
              </p>
              <p className="mt-0.5 text-[11px] text-ink-400">
                {ledger.closing > 0
                  ? labels.debitMeaning
                  : ledger.closing < 0
                    ? labels.creditMeaning
                    : 'Settled'}
              </p>
            </Panel>
          </div>

          <div className="mb-3 flex flex-wrap items-center justify-between gap-2">
            <p className="text-sm text-ink-600">
              <span className="font-medium text-ink-800">{ledger.partyName}</span>
              <span className="ml-2 font-mono text-xs text-ink-400">{ledger.partyCode}</span>
            </p>
            {detailHref && (
              <Button variant="ghost" size="sm" asChild>
                <Link href={detailHref(ledger)}>Open {lower}</Link>
              </Button>
            )}
          </div>

          <DataTable
            columns={columns}
            rows={ledger.lines}
            getRowKey={(row, index) => `${row.entryNumber}-${index}`}
            emptyMessage={`No movements between ${formatDate(ledger.from)} and ${formatDate(ledger.to)}. The balance shown is carried forward.`}
            caption={`${labels.party} ledger`}
            maxHeight="40rem"
          />
        </>
      )}
    </>
  );
}

/**
 * Debit positive is the ledger's convention, but "-₹5,000.00" is not how a
 * dealer describes an advance held or a bill owed. Negative balances are
 * labelled Cr, the way they read on a statement.
 */
function formatBalance(balance: Paise): string {
  if (balance < 0) {
    return `${formatINR(negate(balance))} Cr`;
  }
  return formatINR(balance);
}
