'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Loader2, Plus, Trash2 } from 'lucide-react';

import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { Input, Label } from '@/components/ui/input';
import { SearchSelect } from '@/components/forms/search-select';
import { useIdempotencyKey } from '@/components/forms/use-idempotency-key';
import { formatINR, fromRupees, paise } from '@/lib/money';
import { postManualJournalAction } from '@/server/services/accounting/journal-actions';

interface AccountOption {
  readonly id: string;
  readonly code: string;
  readonly name: string;
  readonly type: string;
}

interface Line {
  readonly key: number;
  accountId: string;
  debit: string;
  credit: string;
  narration: string;
}

const blank = (key: number): Line => ({ key, accountId: '', debit: '', credit: '', narration: '' });

/**
 * A journal entry written by hand — spec §9, §21.
 *
 * The running balance is the whole interface. An entry that does not balance
 * cannot post (spec §22), so the difference is shown as it is typed rather than
 * reported after a failed submission: the person entering it can see the figure
 * they still have to account for.
 *
 * There is deliberately no way to edit a posted entry here. Correction is a
 * reversal and a replacement, which is what the detail screen offers — see the
 * note in journal-entry-service.ts.
 */
export function JournalEntryForm({ accounts }: { readonly accounts: readonly AccountOption[] }) {
  const router = useRouter();
  const [pending, startTransition] = React.useTransition();
  const [error, setError] = React.useState<string | null>(null);

  const [entryDate, setEntryDate] = React.useState(() => new Date().toISOString().slice(0, 10));
  const [narration, setNarration] = React.useState('');
  const [lines, setLines] = React.useState<Line[]>([blank(1), blank(2)]);
  const nextKey = React.useRef(3);

  const idempotency = useIdempotencyKey('manual-journal');

  const options = React.useMemo(
    () => accounts.map((a) => ({ id: a.id, label: `${a.code} · ${a.name}` })),
    [accounts],
  );

  const totals = lines.reduce(
    (sum, l) => ({
      debit: sum.debit + (Number(l.debit) || 0),
      credit: sum.credit + (Number(l.credit) || 0),
    }),
    { debit: 0, credit: 0 },
  );
  const difference = Math.round((totals.debit - totals.credit) * 100) / 100;
  const balanced = difference === 0 && totals.debit > 0;

  const update = (key: number, patch: Partial<Line>) =>
    setLines((current) => current.map((l) => (l.key === key ? { ...l, ...patch } : l)));

  const submit = () => {
    setError(null);
    startTransition(async () => {
      const result = await postManualJournalAction({
        entryDate,
        narration,
        lines: lines
          .filter((l) => l.accountId && (Number(l.debit) > 0 || Number(l.credit) > 0))
          .map((l) => ({
            accountId: l.accountId,
            debit: Number(l.debit) > 0 ? fromRupees(Number(l.debit)) : paise(0),
            credit: Number(l.credit) > 0 ? fromRupees(Number(l.credit)) : paise(0),
            narration: l.narration || null,
          })),
        idempotencyKey: idempotency.key(),
      });

      if (!result.ok) {
        setError(result.error ?? 'The entry could not be posted.');
        return;
      }
      idempotency.renew();
      router.push(`/accounting/journals/${result.id}`);
      router.refresh();
    });
  };

  return (
    <div className="space-y-4">
      {error && (
        <div role="alert" className="rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
          {error}
        </div>
      )}

      <Panel className="p-4">
        <div className="grid gap-4 sm:grid-cols-3">
          <div>
            <Label htmlFor="entry-date" className="mb-1.5 block">Date</Label>
            <Input id="entry-date" type="date" value={entryDate} onChange={(e) => setEntryDate(e.target.value)} />
          </div>
          <div className="sm:col-span-2">
            <Label htmlFor="narration" className="mb-1.5 block">
              Narration<span className="ml-0.5 text-danger-600">*</span>
            </Label>
            <Input
              id="narration" value={narration} onChange={(e) => setNarration(e.target.value)}
              placeholder="Bank charges for August"
            />
            <p className="mt-1 text-xs text-ink-400">
              What this entry is for. It is what makes the ledger readable a year from now.
            </p>
          </div>
        </div>
      </Panel>

      <Panel className="overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full border-collapse text-sm">
            <caption className="sr-only">Journal lines</caption>
            <thead>
              <tr className="border-b border-ink-100">
                {['Account', 'Narration', 'Debit', 'Credit', ''].map((h) => (
                  <th key={h} scope="col" className="px-3 py-2.5 text-left text-[11px] font-semibold uppercase tracking-wide text-ink-500">
                    {h}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {lines.map((line) => (
                <tr key={line.key} className="border-b border-ink-50">
                  <td className="min-w-64 px-3 py-2">
                    <SearchSelect
                      name={`account-${line.key}`}
                      options={options}
                      defaultValue={line.accountId}
                      placeholder="Search the chart of accounts…"
                      onChange={(id) => update(line.key, { accountId: id })}
                    />
                  </td>
                  <td className="px-3 py-2">
                    <Input
                      value={line.narration}
                      onChange={(e) => update(line.key, { narration: e.target.value })}
                      placeholder="Optional"
                    />
                  </td>
                  <td className="px-3 py-2">
                    <Input
                      type="number" step="0.01" min="0" className="numeric w-32"
                      value={line.debit}
                      // A line is one side or the other; typing in one clears
                      // the other rather than letting both carry a figure.
                      onChange={(e) => update(line.key, { debit: e.target.value, credit: '' })}
                    />
                  </td>
                  <td className="px-3 py-2">
                    <Input
                      type="number" step="0.01" min="0" className="numeric w-32"
                      value={line.credit}
                      onChange={(e) => update(line.key, { credit: e.target.value, debit: '' })}
                    />
                  </td>
                  <td className="px-3 py-2">
                    {lines.length > 2 && (
                      <Button
                        variant="ghost" size="icon" aria-label="Remove line"
                        onClick={() => setLines((c) => c.filter((l) => l.key !== line.key))}
                      >
                        <Trash2 className="size-4" aria-hidden />
                      </Button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
            <tfoot>
              <tr className="border-t border-ink-200 bg-ink-50/60">
                <td className="px-3 py-2 text-xs font-medium text-ink-600" colSpan={2}>Total</td>
                <td className="numeric px-3 py-2 font-semibold">{formatINR(fromRupees(totals.debit))}</td>
                <td className="numeric px-3 py-2 font-semibold">{formatINR(fromRupees(totals.credit))}</td>
                <td />
              </tr>
            </tfoot>
          </table>
        </div>

        <div className="flex flex-wrap items-center justify-between gap-3 border-t border-ink-100 p-3">
          <Button variant="secondary" size="sm" onClick={() => setLines((c) => [...c, blank(nextKey.current++)])}>
            <Plus aria-hidden />
            Add line
          </Button>

          <div className="flex items-center gap-3">
            {/* The number the person is working towards. Shown while typing
                rather than after a rejected submission. */}
            <span className={difference === 0 ? 'text-sm text-positive-700' : 'text-sm text-warning-700'}>
              {difference === 0
                ? totals.debit > 0 ? 'Balanced' : 'Nothing entered yet'
                : `Out by ${formatINR(fromRupees(Math.abs(difference)))}`}
            </span>
            <Button onClick={submit} disabled={pending || !balanced || !narration.trim()}>
              {pending && <Loader2 className="animate-spin" aria-hidden />}
              Post entry
            </Button>
          </div>
        </div>
      </Panel>

      <p className="text-xs text-ink-500">
        Posting is final. A posted entry cannot be edited — correcting one means reversing it and
        posting a replacement, so both stay on the record (spec §23).
      </p>
    </div>
  );
}
