'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Check, EyeOff, Link2, Link2Off, Loader2, Scale } from 'lucide-react';

import { Panel, SolidPanel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Input, Label } from '@/components/ui/input';
import { formatINR, fromRupees, paise, subtract } from '@/lib/money';
import { formatDate } from '@/lib/format';
import {
  completeReconciliationAction,
  ignoreLineAction,
  matchLineAction,
  unmatchLineAction,
} from '@/server/services/bank/bank-actions';
import type { MatchSuggestion, StatementLine } from '@/server/services/bank/bank-service';

const CONFIDENCE: Record<string, { variant: 'positive' | 'info' | 'warning'; label: string }> = {
  EXACT: { variant: 'positive', label: 'Exact' },
  LIKELY: { variant: 'info', label: 'Likely' },
  POSSIBLE: { variant: 'warning', label: 'Possible' },
};

/**
 * Bank reconciliation — spec §39.
 *
 * The suggestions are proposals. Each one is accepted individually, and an exact
 * UTR match is distinguished from a same-amount-nearby-date guess, because those
 * two deserve different amounts of attention. "Accept all exact matches" exists
 * because refusing to batch the certain cases just makes people click faster
 * without reading, which is worse.
 */
export function ReconciliationWorkbench({
  bankAccountId,
  accountName,
  bookBalance,
  lines,
  suggestions,
}: {
  readonly bankAccountId: string;
  readonly accountName: string;
  readonly bookBalance: number;
  readonly lines: readonly StatementLine[];
  readonly suggestions: readonly MatchSuggestion[];
}) {
  const router = useRouter();
  const [error, setError] = React.useState<string | null>(null);
  const [notice, setNotice] = React.useState<string | null>(null);
  const [pending, startTransition] = React.useTransition();
  const [busyLine, setBusyLine] = React.useState<number | null>(null);
  const [closing, setClosing] = React.useState(false);

  const [from, setFrom] = React.useState('');
  const [to, setTo] = React.useState('');
  const [statementClosing, setStatementClosing] = React.useState('');
  const [notes, setNotes] = React.useState('');

  const unmatched = lines.filter((l) => l.matchStatus === 'UNMATCHED');
  const matched = lines.filter((l) => l.matchStatus === 'MATCHED');
  const ignored = lines.filter((l) => l.matchStatus === 'IGNORED');
  const exact = suggestions.filter((s) => s.confidence === 'EXACT');

  const run = (lineId: number | null, fn: () => Promise<{ ok: boolean; error?: string; message?: string }>) => {
    setError(null);
    setNotice(null);
    setBusyLine(lineId);
    startTransition(async () => {
      const result = await fn();
      setBusyLine(null);
      if (!result.ok) {
        setError(result.error ?? 'That action could not be completed.');
        return;
      }
      if (result.message) setNotice(result.message);
      router.refresh();
    });
  };

  const acceptAllExact = () => {
    setError(null);
    setNotice(null);
    startTransition(async () => {
      let done = 0;
      for (const s of exact) {
        const result = await matchLineAction(s.statementLineId, s.transactionId);
        if (!result.ok) {
          setError(`Stopped after ${done} matches: ${result.error}`);
          router.refresh();
          return;
        }
        done += 1;
      }
      setNotice(`${done} exact match${done === 1 ? '' : 'es'} accepted.`);
      router.refresh();
    });
  };

  const complete = () => {
    setError(null);
    if (!from || !to) return setError('Enter the period this reconciliation covers.');
    if (statementClosing === '') return setError("Enter the closing balance from the bank's statement.");

    startTransition(async () => {
      const result = await completeReconciliationAction({
        bankAccountId,
        from,
        to,
        statementClosing: Number(statementClosing),
        notes: notes.trim() || null,
      });
      if (!result.ok) {
        setError(result.error ?? 'The reconciliation could not be completed.');
        return;
      }
      setNotice(result.message ?? 'Reconciliation completed.');
      setClosing(false);
      router.refresh();
    });
  };

  const declaredClosing = statementClosing === '' ? null : fromRupees(Number(statementClosing));
  const gap = declaredClosing == null ? null : subtract(declaredClosing, paise(bookBalance));

  return (
    <div className="space-y-4">
      {error && (
        <div role="alert" className="rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
          {error}
        </div>
      )}
      {notice && (
        <div className="rounded-lg border border-positive-200 bg-positive-50 px-3 py-2 text-sm text-positive-700">
          {notice}
        </div>
      )}

      <div className="grid gap-3 sm:grid-cols-4">
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Balance as per books</p>
          <p className="numeric mt-1 text-xl font-semibold text-ink-900">{formatINR(paise(bookBalance))}</p>
        </Panel>
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Unmatched lines</p>
          <p className={`numeric mt-1 text-xl font-semibold ${unmatched.length > 0 ? 'text-warning-700' : 'text-positive-700'}`}>
            {unmatched.length}
          </p>
        </Panel>
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Matched</p>
          <p className="numeric mt-1 text-xl font-semibold text-positive-700">{matched.length}</p>
        </Panel>
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Ignored</p>
          <p className="numeric mt-1 text-xl font-semibold text-ink-500">{ignored.length}</p>
        </Panel>
      </div>

      {suggestions.length > 0 && (
        <SolidPanel className="overflow-hidden">
          <div className="flex flex-wrap items-center justify-between gap-2 border-b border-ink-100 px-4 py-3">
            <div>
              <h2 className="text-sm font-semibold text-ink-900">
                {suggestions.length} suggested match{suggestions.length === 1 ? '' : 'es'}
              </h2>
              <p className="text-xs text-ink-500">
                Each is a proposal. Nothing is reconciled until you accept it.
              </p>
            </div>
            {exact.length > 0 && (
              <Button size="sm" onClick={acceptAllExact} disabled={pending}>
                {pending && <Loader2 className="animate-spin" aria-hidden />}
                Accept {exact.length} exact match{exact.length === 1 ? '' : 'es'}
              </Button>
            )}
          </div>

          <div className="max-h-[26rem] overflow-auto">
            <table className="w-full border-collapse text-sm">
              <thead className="sticky top-0 bg-ink-50 text-left text-xs font-medium text-ink-600">
                <tr>
                  <th className="px-3 py-2">Statement</th>
                  <th className="px-3 py-2">Book entry</th>
                  <th className="px-3 py-2 text-right">Amount</th>
                  <th className="px-3 py-2">Why</th>
                  <th className="px-3 py-2" />
                </tr>
              </thead>
              <tbody>
                {suggestions.map((s) => {
                  const tone = CONFIDENCE[s.confidence] ?? CONFIDENCE.POSSIBLE!;
                  return (
                    <tr key={s.statementLineId} className="border-t border-ink-100 align-top">
                      <td className="px-3 py-2">
                        <span className="block text-xs text-ink-500">{formatDate(s.statementDate)}</span>
                        <span className="block max-w-xs truncate" title={s.narration}>{s.narration}</span>
                      </td>
                      <td className="px-3 py-2">
                        <span className="block text-xs text-ink-500">{formatDate(s.transactionDate)}</span>
                        <span className="block max-w-xs truncate" title={s.particular}>{s.particular}</span>
                      </td>
                      <td className="numeric px-3 py-2 text-right font-medium">{formatINR(s.amount)}</td>
                      <td className="px-3 py-2">
                        <Badge variant={tone.variant}>{tone.label}</Badge>
                        <span className="mt-0.5 block text-[11px] text-ink-500">{s.reason}</span>
                      </td>
                      <td className="px-3 py-2 text-right">
                        <Button size="sm" variant="secondary" disabled={pending}
                          onClick={() => run(s.statementLineId, () => matchLineAction(s.statementLineId, s.transactionId))}>
                          {busyLine === s.statementLineId ? <Loader2 className="animate-spin" aria-hidden /> : <Link2 aria-hidden />}
                          Match
                        </Button>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </SolidPanel>
      )}

      <SolidPanel className="overflow-hidden">
        <div className="border-b border-ink-100 px-4 py-3">
          <h2 className="text-sm font-semibold text-ink-900">Statement lines</h2>
          <p className="text-xs text-ink-500">
            Lines the bank reported, and where each one stands against the books.
          </p>
        </div>

        <div className="max-h-[30rem] overflow-auto">
          <table className="w-full border-collapse text-sm">
            <thead className="sticky top-0 bg-ink-50 text-left text-xs font-medium text-ink-600">
              <tr>
                <th className="px-3 py-2">Date</th>
                <th className="px-3 py-2">Narration</th>
                <th className="px-3 py-2">Reference</th>
                <th className="px-3 py-2 text-right">Debit</th>
                <th className="px-3 py-2 text-right">Credit</th>
                <th className="px-3 py-2">Status</th>
                <th className="px-3 py-2" />
              </tr>
            </thead>
            <tbody>
              {lines.length === 0 && (
                <tr>
                  <td colSpan={7} className="px-3 py-8 text-center text-sm text-ink-500">
                    No statement lines staged for this account. Import a statement first.
                  </td>
                </tr>
              )}
              {lines.map((line) => (
                <tr key={line.id} className="border-t border-ink-100">
                  <td className="whitespace-nowrap px-3 py-2">{formatDate(line.statementDate)}</td>
                  <td className="max-w-sm truncate px-3 py-2" title={line.narration}>{line.narration}</td>
                  <td className="px-3 py-2 font-mono text-xs text-ink-500">{line.utr ?? line.reference ?? '—'}</td>
                  <td className="numeric px-3 py-2 text-right text-danger-700">
                    {line.debit > 0 ? formatINR(line.debit) : '—'}
                  </td>
                  <td className="numeric px-3 py-2 text-right text-positive-700">
                    {line.credit > 0 ? formatINR(line.credit) : '—'}
                  </td>
                  <td className="px-3 py-2">
                    <Badge variant={
                      line.matchStatus === 'MATCHED' ? 'positive'
                        : line.matchStatus === 'IGNORED' ? 'neutral' : 'warning'
                    }>
                      {line.matchStatus}
                    </Badge>
                    {line.locked && <span className="ml-1 text-[11px] text-ink-400">settled</span>}
                  </td>
                  <td className="px-3 py-2 text-right">
                    {line.matchStatus === 'MATCHED' && !line.locked && (
                      <Button size="sm" variant="ghost" disabled={pending}
                        onClick={() => run(line.id, () => unmatchLineAction(line.id))}>
                        {busyLine === line.id ? <Loader2 className="animate-spin" aria-hidden /> : <Link2Off aria-hidden />}
                        Unmatch
                      </Button>
                    )}
                    {line.matchStatus === 'UNMATCHED' && (
                      <Button size="sm" variant="ghost" disabled={pending}
                        onClick={() => run(line.id, () => ignoreLineAction(line.id))}>
                        {busyLine === line.id ? <Loader2 className="animate-spin" aria-hidden /> : <EyeOff aria-hidden />}
                        Ignore
                      </Button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </SolidPanel>

      <Panel className="p-5">
        {!closing ? (
          <div className="flex flex-wrap items-center justify-between gap-3">
            <div>
              <h2 className="text-sm font-semibold text-ink-900">Complete the reconciliation</h2>
              <p className="text-xs text-ink-500">
                Records the period, the bank&rsquo;s closing balance and what remains unexplained.
              </p>
            </div>
            <Button size="sm" onClick={() => setClosing(true)}>
              <Scale aria-hidden />
              Complete for a period
            </Button>
          </div>
        ) : (
          <>
            <h2 className="text-sm font-semibold text-ink-900">Complete the reconciliation — {accountName}</h2>
            <div className="mt-4 grid gap-4 sm:grid-cols-3">
              <div>
                <Label htmlFor="recon-from" className="mb-1.5 block">From</Label>
                <Input id="recon-from" type="date" value={from} onChange={(e) => setFrom(e.target.value)} />
              </div>
              <div>
                <Label htmlFor="recon-to" className="mb-1.5 block">To</Label>
                <Input id="recon-to" type="date" value={to} onChange={(e) => setTo(e.target.value)} />
              </div>
              <div>
                <Label htmlFor="recon-closing" className="mb-1.5 block">Closing balance per statement</Label>
                <div className="relative">
                  <span className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-sm text-ink-400">₹</span>
                  <Input id="recon-closing" type="number" step="0.01" className="pl-7"
                    value={statementClosing} onChange={(e) => setStatementClosing(e.target.value)} />
                </div>
              </div>
              <div className="sm:col-span-3">
                <Label htmlFor="recon-notes" className="mb-1.5 block">Notes</Label>
                <textarea id="recon-notes" rows={2} value={notes} onChange={(e) => setNotes(e.target.value)}
                  placeholder="Anything left unexplained, and why"
                  className="w-full rounded-lg border border-ink-200 bg-white px-3 py-2 text-sm shadow-sm" />
              </div>
            </div>

            {gap != null && (
              <div className={`mt-4 flex items-center justify-between rounded-lg border px-4 py-3 ${
                gap === 0 ? 'border-positive-200 bg-positive-50' : 'border-warning-200 bg-warning-50'
              }`}>
                <span className={`text-sm font-medium ${gap === 0 ? 'text-positive-800' : 'text-warning-900'}`}>
                  {gap === 0 ? 'Statement and books agree' : 'Difference still to explain'}
                </span>
                <span className={`numeric text-lg font-bold ${gap === 0 ? 'text-positive-800' : 'text-warning-900'}`}>
                  {formatINR(paise(Math.abs(gap)))}
                </span>
              </div>
            )}

            {unmatched.length > 0 && (
              <p className="mt-3 rounded-lg border border-warning-200 bg-warning-50 px-3 py-2 text-xs text-warning-800">
                {unmatched.length} statement line{unmatched.length === 1 ? '' : 's'} remain unmatched. Completing
                now records them as unexplained rather than resolving them.
              </p>
            )}

            <div className="mt-4 flex gap-2">
              <Button size="sm" onClick={complete} disabled={pending}>
                {pending ? <Loader2 className="animate-spin" aria-hidden /> : <Check aria-hidden />}
                Complete reconciliation
              </Button>
              <Button variant="secondary" size="sm" onClick={() => setClosing(false)} disabled={pending}>
                Cancel
              </Button>
            </div>
          </>
        )}
      </Panel>
    </div>
  );
}
