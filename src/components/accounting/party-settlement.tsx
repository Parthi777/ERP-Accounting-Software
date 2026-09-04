'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Check, ChevronRight, Loader2, TriangleAlert } from 'lucide-react';

import type {
  OpenItem,
  PartySettlement as Settlement,
} from '@/server/services/accounting/settlement-service';
import { splitPaymentAction } from '@/server/services/accounting/settlement-actions';
import { Panel, SolidPanel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Input, Label } from '@/components/ui/input';
import { add, formatINR, fromRupees, negate, subtract, toRupees, ZERO, type Paise } from '@/lib/money';
import { formatDate } from '@/lib/format';

/**
 * Splitting a payment across the bills it settles — spec §41, §51, §53.
 *
 * The cashier records money as it comes in; this is where Accounts says what it
 * paid for. The screen is built around one number the accountant can check
 * without leaving the page:
 *
 *     unpaid bills − unapplied payments = the ledger closing balance
 *
 * That line is shown first and updated by the server after every save, because
 * a settlement screen whose totals only agree with themselves is worth nothing.
 *
 * Amounts are typed in rupees and held as strings while being typed — a
 * half-entered "12." is not a number and must not be rounded into one — and
 * converted to paise once, on the way to the server (see src/lib/money.ts).
 */

/**
 * The words this screen uses for a debit and a credit.
 *
 * Kept as a parameter rather than hardcoded because the two are not the same
 * for every party: a customer's bill is a debit, a supplier's is a credit. Only
 * the customer set exists today — the supplier ledger would need the sides
 * swapped, not just relabelled — but keeping the seam here means adding it later
 * is a second constant rather than a rewrite.
 */
export interface SettlementLabels {
  /** 'customer' — used mid-sentence, so lower case. */
  readonly party: string;
  /** What one debit is called: an invoice to a customer. */
  readonly bill: string;
  /** Heading over the outstanding side. */
  readonly billsHeading: string;
  /** What one credit is called: a receipt from a customer. */
  readonly payment: string;
  /** Plural of the above, mid-sentence. */
  readonly payments: string;
  /** Heading over the payments side. */
  readonly paymentsHeading: string;
}

export const CUSTOMER_SETTLEMENT_LABELS: SettlementLabels = {
  party: 'customer',
  bill: 'Invoice',
  billsHeading: 'Unpaid invoices',
  payment: 'Receipt',
  payments: 'receipts',
  paymentsHeading: 'Receipts to allocate',
};

export function PartySettlement({
  settlement,
  labels,
}: {
  readonly settlement: Settlement;
  readonly labels: SettlementLabels;
}) {
  const router = useRouter();
  const [openPaymentId, setOpenPaymentId] = React.useState<string | null>(null);
  const [notice, setNotice] = React.useState<string | null>(null);

  const payments = [...settlement.openPayments, ...settlement.settledPayments];
  const billsById = new Map<string, OpenItem>(
    [...settlement.openBills, ...settlement.settledBills].map((bill) => [bill.lineId, bill]),
  );

  return (
    <section className="mt-8" aria-labelledby="settlement-heading">
      <div className="mb-3 flex flex-wrap items-baseline justify-between gap-2">
        <div>
          <h2 id="settlement-heading" className="text-sm font-semibold text-ink-900">
            Bill-wise settlement
          </h2>
          <p className="text-xs text-ink-500">
            Split each {labels.payment.toLowerCase()} across the {labels.bill.toLowerCase()}s it
            pays. Nothing is posted — the balance does not move, the detail behind it appears.
          </p>
        </div>
        <p className="text-[11px] text-ink-400">Covers the whole account, not the dates above.</p>
      </div>

      <TallyStrip settlement={settlement} labels={labels} />

      {notice && (
        <div
          role="status"
          className="mt-3 rounded-lg border border-positive-200 bg-positive-50 px-3 py-2 text-sm text-positive-700"
        >
          {notice}
        </div>
      )}

      <div className="mt-4 grid gap-4 xl:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
        <div>
          <h3 className="mb-2 text-xs font-semibold uppercase tracking-wide text-ink-500">
            {labels.paymentsHeading}
          </h3>

          {payments.length === 0 ? (
            <SolidPanel className="p-6 text-center text-sm text-ink-400">
              Nothing has been received from this {labels.party} yet.
            </SolidPanel>
          ) : (
            <ul className="space-y-2">
              {payments.map((payment) => (
                <PaymentRow
                  key={payment.lineId}
                  payment={payment}
                  labels={labels}
                  splitCount={(settlement.splits[payment.lineId] ?? []).length}
                  expanded={openPaymentId === payment.lineId}
                  canSettle={settlement.canSettle}
                  onToggle={() =>
                    setOpenPaymentId((current) =>
                      current === payment.lineId ? null : payment.lineId,
                    )
                  }
                >
                  <SplitEditor
                    payment={payment}
                    bills={billsFor(payment, settlement, billsById)}
                    existing={settlement.splits[payment.lineId] ?? []}
                    labels={labels}
                    onSaved={(message) => {
                      setNotice(message);
                      setOpenPaymentId(null);
                      router.refresh();
                    }}
                    onCancel={() => setOpenPaymentId(null)}
                  />
                </PaymentRow>
              ))}
            </ul>
          )}

          {settlement.historyTruncated && (
            <p className="mt-2 text-[11px] text-ink-400">
              Older {labels.payments} that are already fully allocated are not listed.
            </p>
          )}
        </div>

        <div>
          <h3 className="mb-2 text-xs font-semibold uppercase tracking-wide text-ink-500">
            {labels.billsHeading}
          </h3>
          <OpenBills bills={settlement.openBills} labels={labels} />
        </div>
      </div>
    </section>
  );
}

/**
 * The bills one payment may be set against: everything still open, plus
 * anything this payment itself has already closed. Without the second half a
 * completed split could be read and never revised.
 */
function billsFor(
  payment: OpenItem,
  settlement: Settlement,
  billsById: Map<string, OpenItem>,
): readonly OpenItem[] {
  const open = settlement.openBills;
  const openIds = new Set(open.map((bill) => bill.lineId));
  const closedByThisPayment = (settlement.splits[payment.lineId] ?? [])
    .filter((link) => !openIds.has(link.debitLineId))
    .map((link) => billsById.get(link.debitLineId))
    .filter((bill): bill is OpenItem => bill !== undefined);

  return [...open, ...closedByThisPayment].sort((a, b) => a.date.localeCompare(b.date));
}

/**
 * The reconciliation, stated as an equation rather than three unrelated totals.
 *
 * The verdict is not decoration. Both sides are derived from the same journal
 * lines, so they cannot disagree unless something is wrong with the data — and
 * an accountant who is about to act on this page should be told that before
 * they do, not after.
 */
function TallyStrip({
  settlement,
  labels,
}: {
  readonly settlement: Settlement;
  readonly labels: SettlementLabels;
}) {
  const difference = subtract(
    subtract(settlement.totalOpenBills, settlement.totalUnapplied),
    settlement.ledgerClosing,
  );

  return (
    <Panel className="p-4">
      <div className="flex flex-wrap items-end gap-x-6 gap-y-3">
        <Figure label={`Unpaid ${labels.bill.toLowerCase()}s`} value={settlement.totalOpenBills} />
        <Operator>−</Operator>
        <Figure label={`Unallocated ${labels.payments}`} value={settlement.totalUnapplied} />
        <Operator>=</Operator>
        <Figure label="Ledger closing balance" value={settlement.ledgerClosing} emphasis />

        <div className="ml-auto">
          {settlement.tallies ? (
            <Badge variant="positive">
              <Check aria-hidden className="size-3.5" />
              Tallied
            </Badge>
          ) : (
            <Badge variant="danger">
              <TriangleAlert aria-hidden className="size-3.5" />
              Out by {formatINR(difference < 0 ? negate(difference) : difference)}
            </Badge>
          )}
        </div>
      </div>
    </Panel>
  );
}

function Figure({
  label,
  value,
  emphasis = false,
}: {
  readonly label: string;
  readonly value: Paise;
  readonly emphasis?: boolean;
}) {
  return (
    <div>
      <p className="text-xs text-ink-500">{label}</p>
      <p
        className={
          emphasis
            ? 'numeric mt-0.5 text-lg font-bold text-ink-900'
            : 'numeric mt-0.5 text-lg font-semibold text-ink-800'
        }
      >
        {formatINR(value)}
      </p>
    </div>
  );
}

function Operator({ children }: { readonly children: React.ReactNode }) {
  return <span aria-hidden className="pb-1 text-lg font-medium text-ink-300">{children}</span>;
}

function PaymentRow({
  payment,
  labels,
  splitCount,
  expanded,
  canSettle,
  onToggle,
  children,
}: {
  readonly payment: OpenItem;
  readonly labels: SettlementLabels;
  readonly splitCount: number;
  readonly expanded: boolean;
  readonly canSettle: boolean;
  readonly onToggle: () => void;
  readonly children: React.ReactNode;
}) {
  const fully = payment.outstanding === 0;

  return (
    <li>
      <SolidPanel className="overflow-hidden">
        <div className="flex flex-wrap items-center gap-3 px-4 py-3">
          <div className="min-w-0 flex-1">
            <p className="flex flex-wrap items-center gap-2 text-sm font-medium text-ink-800">
              <span className="font-mono text-xs text-ink-600">{payment.documentRef}</span>
              <span className="text-xs font-normal text-ink-400">{formatDate(payment.date)}</span>
              {fully ? (
                <Badge variant="neutral">Allocated</Badge>
              ) : payment.allocated > 0 ? (
                <Badge variant="warning">Part allocated</Badge>
              ) : (
                <Badge variant="info">On account</Badge>
              )}
            </p>
            <p className="mt-0.5 truncate text-xs text-ink-500">
              {payment.particulars ?? '—'}
              <span className="ml-2 font-mono text-ink-400">
                {payment.accountCode} · {payment.accountName}
              </span>
            </p>
          </div>

          <div className="text-right">
            <p className="numeric text-sm font-semibold text-ink-800">{formatINR(payment.amount)}</p>
            <p className="numeric text-xs text-ink-500">
              {fully ? 'fully allocated' : `${formatINR(payment.outstanding)} unallocated`}
            </p>
          </div>

          <Button
            variant={expanded ? 'secondary' : 'ghost'}
            size="sm"
            onClick={onToggle}
            aria-expanded={expanded}
          >
            <ChevronRight
              aria-hidden
              className={expanded ? 'rotate-90 transition-transform' : 'transition-transform'}
            />
            {canSettle ? (splitCount > 0 ? 'Revise split' : 'Split') : 'View split'}
          </Button>
        </div>

        {expanded && (
          <div className="border-t border-ink-100 bg-brand-50/30 px-4 py-4">
            {canSettle ? (
              children
            ) : (
              <p className="text-sm text-ink-600">
                {splitCount > 0
                  ? `This ${labels.payment.toLowerCase()} is set against ${splitCount} ${splitCount === 1 ? labels.bill.toLowerCase() : `${labels.bill.toLowerCase()}s`}.`
                  : `This ${labels.payment.toLowerCase()} has not been allocated yet.`}{' '}
                Only Accounts can change a settlement.
              </p>
            )}
          </div>
        )}
      </SolidPanel>
    </li>
  );
}

/**
 * The split itself.
 *
 * Each bill gets one field, in rupees. The footer is the arithmetic the
 * accountant is doing anyway — received, allocated, left on account — so the
 * mistake is visible before Save rather than in an error afterwards.
 */
function SplitEditor({
  payment,
  bills,
  existing,
  labels,
  onSaved,
  onCancel,
}: {
  readonly payment: OpenItem;
  readonly bills: readonly OpenItem[];
  readonly existing: readonly { readonly debitLineId: string; readonly amount: Paise }[];
  readonly labels: SettlementLabels;
  readonly onSaved: (message: string) => void;
  readonly onCancel: () => void;
}) {
  const existingByBill = React.useMemo(
    () => new Map(existing.map((link) => [link.debitLineId, link.amount])),
    [existing],
  );

  const [amounts, setAmounts] = React.useState<Record<string, string>>(() =>
    Object.fromEntries(
      existing
        .filter((link) => link.amount > 0)
        .map((link) => [link.debitLineId, String(toRupees(link.amount))]),
    ),
  );
  const [note, setNote] = React.useState('');
  const [error, setError] = React.useState<string | null>(null);
  const [pending, startTransition] = React.useTransition();

  /**
   * What this payment may put against a bill: what is still owing on it, plus
   * whatever this same payment already contributes — that part is about to be
   * released and re-entered, so it is headroom, not a competing claim.
   */
  const capacityOf = (bill: OpenItem): Paise =>
    add(bill.outstanding, existingByBill.get(bill.lineId) ?? ZERO);

  const entered = (billId: string): Paise => {
    const value = Number(amounts[billId] ?? '');
    return Number.isFinite(value) && value > 0 ? fromRupees(value) : ZERO;
  };

  const allocated = bills.reduce((sum, bill) => add(sum, entered(bill.lineId)), ZERO);
  const remaining = subtract(payment.amount, allocated);

  /** Oldest bill first, until the money runs out — how a dealer settles by hand. */
  const fillOldestFirst = () => {
    let left = payment.amount;
    const next: Record<string, string> = {};
    for (const bill of bills) {
      if (left <= 0) break;
      const capacity = capacityOf(bill);
      const take = (capacity < left ? capacity : left) as Paise;
      if (take > 0) {
        next[bill.lineId] = String(toRupees(take));
        left = subtract(left, take);
      }
    }
    setAmounts(next);
    setError(null);
  };

  const submit = (event: React.FormEvent) => {
    event.preventDefault();
    setError(null);

    if (remaining < 0) {
      return setError(
        `The split is ${formatINR(negate(remaining))} more than this ${labels.payment.toLowerCase()}.`,
      );
    }
    const over = bills.find((bill) => entered(bill.lineId) > capacityOf(bill));
    if (over) {
      return setError(
        `${over.documentRef} has only ${formatINR(capacityOf(over))} left to settle.`,
      );
    }

    startTransition(async () => {
      const result = await splitPaymentAction({
        creditLineId: payment.lineId,
        allocations: bills
          .map((bill) => ({ debitLineId: bill.lineId, amount: entered(bill.lineId) }))
          .filter((line) => line.amount > 0),
        note: note.trim() || null,
      });

      if (!result.ok) {
        setError(result.error ?? 'The split could not be saved.');
        return;
      }
      onSaved(result.message ?? 'The split was saved.');
    });
  };

  if (bills.length === 0) {
    return (
      <p className="text-sm text-ink-600">
        There is nothing outstanding to set this {labels.payment.toLowerCase()} against. It stays on
        account until a {labels.bill.toLowerCase()} is raised.
      </p>
    );
  }

  return (
    <form onSubmit={submit} className="space-y-3" noValidate>
      {error && (
        <div
          role="alert"
          className="rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700"
        >
          {error}
        </div>
      )}

      <div className="overflow-x-auto rounded-lg border border-ink-100 bg-white">
        <table className="w-full border-collapse text-sm">
          <caption className="sr-only">
            Bills this {labels.payment.toLowerCase()} may be set against
          </caption>
          <thead>
            <tr className="border-b border-ink-100">
              <th scope="col" className="px-3 py-2 text-left text-[11px] font-semibold uppercase tracking-wide text-ink-500">
                {labels.bill}
              </th>
              <th scope="col" className="px-3 py-2 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">
                Age
              </th>
              <th scope="col" className="px-3 py-2 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">
                Still due
              </th>
              <th scope="col" className="px-3 py-2 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">
                Set against it
              </th>
            </tr>
          </thead>
          <tbody>
            {bills.map((bill) => (
              <tr key={bill.lineId} className="border-t border-ink-100">
                <td className="px-3 py-2">
                  <span className="font-mono text-xs text-ink-700">{bill.documentRef}</span>
                  <span className="ml-2 text-xs text-ink-400">{formatDate(bill.date)}</span>
                  {bill.particulars && (
                    <span className="block max-w-xs truncate text-xs text-ink-500">
                      {bill.particulars}
                    </span>
                  )}
                </td>
                <td className="numeric px-3 py-2 text-right text-xs text-ink-500">
                  {bill.ageDays}d
                </td>
                <td className="numeric px-3 py-2 text-right text-sm text-ink-700">
                  {formatINR(capacityOf(bill))}
                </td>
                <td className="px-3 py-2 text-right">
                  <Input
                    type="number"
                    step="0.01"
                    min="0"
                    inputMode="decimal"
                    aria-label={`Amount set against ${bill.documentRef}`}
                    className="ml-auto h-8 w-32 text-right"
                    value={amounts[bill.lineId] ?? ''}
                    onChange={(event) =>
                      setAmounts((current) => ({ ...current, [bill.lineId]: event.target.value }))
                    }
                  />
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="flex flex-wrap items-center justify-between gap-3 rounded-lg border border-brand-200 bg-brand-50 px-4 py-2.5">
        <div className="flex flex-wrap gap-x-6 gap-y-1 text-xs">
          <span className="text-brand-800">
            Received <span className="numeric font-semibold">{formatINR(payment.amount)}</span>
          </span>
          <span className="text-brand-800">
            Allocated <span className="numeric font-semibold">{formatINR(allocated)}</span>
          </span>
          <span className={remaining < 0 ? 'text-danger-700' : 'text-brand-800'}>
            {remaining < 0 ? 'Over by ' : 'Left on account '}
            <span className="numeric font-semibold">
              {formatINR(remaining < 0 ? negate(remaining) : remaining)}
            </span>
          </span>
        </div>
        <Button type="button" variant="ghost" size="sm" onClick={fillOldestFirst}>
          Oldest first
        </Button>
      </div>

      <div>
        <Label htmlFor={`note-${payment.lineId}`} className="mb-1.5 block text-xs">
          Note
        </Label>
        <Input
          id={`note-${payment.lineId}`}
          value={note}
          onChange={(event) => setNote(event.target.value)}
          placeholder="Optional — why this split was made"
        />
      </div>

      <div className="flex flex-wrap items-center gap-2">
        <Button type="submit" size="sm" disabled={pending}>
          {pending && <Loader2 className="animate-spin" aria-hidden />}
          {pending ? 'Saving…' : 'Save split'}
        </Button>
        <Button type="button" variant="ghost" size="sm" onClick={onCancel} disabled={pending}>
          Cancel
        </Button>
        <Button
          type="button"
          variant="ghost"
          size="sm"
          onClick={() => setAmounts({})}
          disabled={pending}
        >
          Clear
        </Button>
        <p className="text-[11px] text-ink-400">
          Saving replaces this {labels.payment.toLowerCase()}&rsquo;s whole split. No journal is
          written.
        </p>
      </div>
    </form>
  );
}

function OpenBills({
  bills,
  labels,
}: {
  readonly bills: readonly OpenItem[];
  readonly labels: SettlementLabels;
}) {
  if (bills.length === 0) {
    return (
      <SolidPanel className="p-6 text-center text-sm text-ink-400">
        Nothing is outstanding. Every {labels.bill.toLowerCase()} has been settled.
      </SolidPanel>
    );
  }

  return (
    <SolidPanel className="overflow-hidden">
      <div className="overflow-auto" style={{ maxHeight: '28rem' }}>
        <table className="w-full border-collapse text-sm">
          <caption className="sr-only">{labels.billsHeading}</caption>
          <thead className="sticky top-0 bg-white">
            <tr>
              <th scope="col" className="px-4 py-2.5 text-left text-[11px] font-semibold uppercase tracking-wide text-ink-500">
                {labels.bill}
              </th>
              <th scope="col" className="px-4 py-2.5 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">
                Age
              </th>
              <th scope="col" className="px-4 py-2.5 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">
                Amount
              </th>
              <th scope="col" className="px-4 py-2.5 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">
                Settled
              </th>
              <th scope="col" className="px-4 py-2.5 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">
                Still due
              </th>
            </tr>
          </thead>
          <tbody>
            {bills.map((bill) => (
              <tr key={bill.lineId} className="border-t border-ink-100 hover:bg-brand-50/40">
                <td className="px-4 py-2">
                  <span className="font-mono text-xs text-ink-700">{bill.documentRef}</span>
                  <span className="ml-2 text-xs text-ink-400">{formatDate(bill.date)}</span>
                  {bill.particulars && (
                    <span className="block max-w-sm truncate text-xs text-ink-500">
                      {bill.particulars}
                    </span>
                  )}
                </td>
                <td className="numeric px-4 py-2 text-right text-xs">
                  <span className={bill.ageDays > 30 ? 'text-danger-600' : 'text-ink-500'}>
                    {bill.ageDays}d
                  </span>
                </td>
                <td className="numeric px-4 py-2 text-right text-ink-700">
                  {formatINR(bill.amount)}
                </td>
                <td className="numeric px-4 py-2 text-right text-ink-500">
                  {bill.allocated > 0 ? formatINR(bill.allocated) : <span className="text-ink-300">—</span>}
                </td>
                <td className="numeric px-4 py-2 text-right font-medium text-ink-900">
                  {formatINR(bill.outstanding)}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </SolidPanel>
  );
}
