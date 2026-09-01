'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Loader2, Lock, Unlock } from 'lucide-react';

import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { Input, Label } from '@/components/ui/input';
import { add, formatINR, fromRupees, paise, subtract } from '@/lib/money';
import { closeCashDayAction, reopenCashDayAction } from '@/server/services/cash/cash-actions';

/** Indian currency in circulation, largest first — the order a drawer is counted in. */
const DENOMINATIONS = [500, 200, 100, 50, 20, 10, 5, 2, 1] as const;

/**
 * The daily cash close — spec §36, §60.15.
 *
 * The counted total comes from the denomination grid, and the difference against
 * the expected closing is computed here for the cashier's benefit and again in
 * the database, which is the copy that counts. Neither can be typed over.
 */
export function DayCloseForm({
  businessDate,
  branchName,
  expectedClosing,
  status,
  physicalCash,
  difference,
  remarks: savedRemarks,
  canClose,
  canReopen,
}: {
  readonly businessDate: string;
  readonly branchName: string;
  readonly expectedClosing: number;
  readonly status: string;
  readonly physicalCash: number | null;
  readonly difference: number | null;
  readonly remarks: string | null;
  readonly canClose: boolean;
  readonly canReopen: boolean;
}) {
  const router = useRouter();
  const [error, setError] = React.useState<string | null>(null);
  const [pending, startTransition] = React.useTransition();
  const [counts, setCounts] = React.useState<Record<number, string>>({});
  const [remarks, setRemarks] = React.useState('');
  const [reopening, setReopening] = React.useState(false);
  const [reason, setReason] = React.useState('');

  const closed = status === 'CLOSED';
  const expected = paise(expectedClosing);

  const counted = DENOMINATIONS.reduce((total, note) => {
    const qty = Number(counts[note]) || 0;
    return add(total, fromRupees(note * qty));
  }, paise(0));

  const gap = subtract(counted, expected);

  const submit = (event: React.FormEvent) => {
    event.preventDefault();
    setError(null);

    const anyCounted = DENOMINATIONS.some((n) => Number(counts[n]) > 0);
    if (!anyCounted) {
      return setError('Count the drawer before closing. Enter the number of notes of each denomination.');
    }

    startTransition(async () => {
      const denominations: Record<string, number> = {};
      for (const note of DENOMINATIONS) {
        const qty = Number(counts[note]) || 0;
        if (qty > 0) denominations[String(note)] = qty;
      }

      const result = await closeCashDayAction({
        date: businessDate,
        physicalCash: counted / 100,
        denominations,
        remarks: remarks.trim() || null,
      });

      if (!result.ok) {
        setError(result.error ?? 'The day could not be closed.');
        return;
      }
      router.refresh();
    });
  };

  const reopen = () => {
    setError(null);
    if (!reason.trim()) return setError('A reason is required to reopen a closed day.');

    startTransition(async () => {
      const result = await reopenCashDayAction({ date: businessDate, reason: reason.trim() });
      if (!result.ok) {
        setError(result.error ?? 'The day could not be reopened.');
        return;
      }
      setReopening(false);
      setReason('');
      router.refresh();
    });
  };

  if (closed) {
    const savedGap = difference ?? 0;
    return (
      <Panel className="p-5">
        {error && (
          <div role="alert" className="mb-3 rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
            {error}
          </div>
        )}

        <div className="flex items-center gap-2">
          <Lock className="text-ink-500" aria-hidden />
          <h2 className="text-sm font-semibold text-ink-900">
            {businessDate} is closed at {branchName}
          </h2>
        </div>

        <dl className="mt-4 grid gap-3 sm:grid-cols-3">
          <div className="rounded-lg border border-ink-100 bg-ink-50/60 px-4 py-3">
            <dt className="text-xs text-ink-500">Expected</dt>
            <dd className="numeric mt-1 text-lg font-semibold text-ink-900">{formatINR(expected)}</dd>
          </div>
          <div className="rounded-lg border border-ink-100 bg-ink-50/60 px-4 py-3">
            <dt className="text-xs text-ink-500">Counted</dt>
            <dd className="numeric mt-1 text-lg font-semibold text-ink-900">
              {physicalCash != null ? formatINR(paise(physicalCash)) : '—'}
            </dd>
          </div>
          <div className={`rounded-lg border px-4 py-3 ${
            savedGap === 0 ? 'border-positive-200 bg-positive-50' : 'border-danger-200 bg-danger-50'
          }`}>
            <dt className={`text-xs ${savedGap === 0 ? 'text-positive-700' : 'text-danger-700'}`}>
              {savedGap === 0 ? 'Tallied' : savedGap > 0 ? 'Excess' : 'Shortage'}
            </dt>
            <dd className={`numeric mt-1 text-lg font-bold ${savedGap === 0 ? 'text-positive-800' : 'text-danger-800'}`}>
              {formatINR(paise(Math.abs(savedGap)))}
            </dd>
          </div>
        </dl>

        {savedRemarks && <p className="mt-3 text-sm text-ink-600">{savedRemarks}</p>}

        {canReopen && !reopening && (
          <Button variant="secondary" size="sm" className="mt-4" onClick={() => setReopening(true)}>
            <Unlock aria-hidden />
            Reopen for adjustment
          </Button>
        )}

        {canReopen && reopening && (
          <div className="mt-4 rounded-lg border border-warning-200 bg-warning-50 p-4">
            <Label htmlFor="reopen-reason" className="mb-1.5 block">
              Why is this day being reopened?
            </Label>
            <textarea id="reopen-reason" rows={2} value={reason} onChange={(e) => setReason(e.target.value)}
              className="w-full rounded-lg border border-ink-200 bg-white px-3 py-2 text-sm shadow-sm" />
            <p className="mt-1 text-xs text-warning-800">
              The reason is recorded permanently in the audit trail.
            </p>
            <div className="mt-3 flex gap-2">
              <Button size="sm" disabled={pending || !reason.trim()} onClick={reopen}>
                {pending && <Loader2 className="animate-spin" aria-hidden />}
                Reopen the day
              </Button>
              <Button variant="secondary" size="sm" onClick={() => setReopening(false)} disabled={pending}>
                Cancel
              </Button>
            </div>
          </div>
        )}
      </Panel>
    );
  }

  if (!canClose) {
    return (
      <Panel className="p-5">
        <p className="text-sm text-ink-700">
          {businessDate} is open at {branchName}. Expected closing is{' '}
          <span className="numeric font-semibold">{formatINR(expected)}</span>.
        </p>
        <p className="mt-1 text-xs text-ink-500">
          You do not have permission to count and close the day.
        </p>
      </Panel>
    );
  }

  return (
    <form onSubmit={submit} className="space-y-4" noValidate>
      {error && (
        <div role="alert" className="rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
          {error}
        </div>
      )}

      <Panel className="p-5">
        <h2 className="text-sm font-semibold text-ink-900">Count the drawer</h2>
        <p className="mb-4 text-xs text-ink-500">
          {branchName} · {businessDate}. Enter how many notes and coins of each denomination are in hand.
        </p>

        <div className="grid gap-3 sm:grid-cols-3">
          {DENOMINATIONS.map((note) => {
            const qty = Number(counts[note]) || 0;
            return (
              <div key={note} className="flex items-center gap-2 rounded-lg border border-ink-100 px-3 py-2">
                <span className="numeric w-12 shrink-0 text-sm font-medium text-ink-700">₹{note}</span>
                <span className="text-ink-300" aria-hidden>×</span>
                <Input
                  type="number" min="0" step="1" inputMode="numeric"
                  aria-label={`Number of ₹${note} notes`}
                  value={counts[note] ?? ''}
                  onChange={(e) => setCounts((c) => ({ ...c, [note]: e.target.value }))}
                  className="h-8"
                />
                <span className="numeric w-24 shrink-0 text-right text-sm text-ink-500">
                  {qty > 0 ? formatINR(fromRupees(note * qty)) : '—'}
                </span>
              </div>
            );
          })}
        </div>
      </Panel>

      <Panel className="p-5">
        <dl className="grid gap-3 sm:grid-cols-3">
          <div className="rounded-lg border border-ink-100 bg-ink-50/60 px-4 py-3">
            <dt className="text-xs text-ink-500">Expected closing</dt>
            <dd className="numeric mt-1 text-lg font-semibold text-ink-900">{formatINR(expected)}</dd>
          </div>
          <div className="rounded-lg border border-ink-100 bg-ink-50/60 px-4 py-3">
            <dt className="text-xs text-ink-500">Counted</dt>
            <dd className="numeric mt-1 text-lg font-semibold text-ink-900">{formatINR(counted)}</dd>
          </div>
          <div className={`rounded-lg border px-4 py-3 ${
            gap === 0 ? 'border-positive-200 bg-positive-50' : 'border-warning-200 bg-warning-50'
          }`}>
            <dt className={`text-xs ${gap === 0 ? 'text-positive-700' : 'text-warning-800'}`}>
              {gap === 0 ? 'Tallies' : gap > 0 ? 'Excess' : 'Shortage'}
            </dt>
            <dd className={`numeric mt-1 text-lg font-bold ${gap === 0 ? 'text-positive-800' : 'text-warning-900'}`}>
              {formatINR(paise(Math.abs(gap)))}
            </dd>
          </div>
        </dl>

        <div className="mt-4">
          <Label htmlFor="remarks" className="mb-1.5 block">
            Remarks{gap !== 0 && <span className="ml-0.5 text-danger-600">*</span>}
          </Label>
          <textarea id="remarks" rows={2} value={remarks} onChange={(e) => setRemarks(e.target.value)}
            placeholder={gap !== 0 ? 'Explain the difference' : 'Optional'}
            className="w-full rounded-lg border border-ink-200 bg-white px-3 py-2 text-sm shadow-sm" />
        </div>

        {gap !== 0 && (
          <p className="mt-3 rounded-lg border border-warning-200 bg-warning-50 px-3 py-2 text-xs text-warning-800">
            The count does not match the book. Closing is still allowed — the difference is recorded
            against this day and stays visible in the closing history.
          </p>
        )}
      </Panel>

      <Button type="submit" disabled={pending || (gap !== 0 && !remarks.trim())}>
        {pending && <Loader2 className="animate-spin" aria-hidden />}
        {pending ? 'Closing…' : 'Close the day'}
      </Button>
    </form>
  );
}
