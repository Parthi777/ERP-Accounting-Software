'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Loader2, Plus, Trash2 } from 'lucide-react';

import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { AmountInput } from '@/components/forms/amount-input';
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

export type JournalPartyType = 'CUSTOMER' | 'SUPPLIER' | 'FINANCE_COMPANY';

/** Someone a line can be held against — a customer, supplier or finance company. */
export interface PartyOption {
  readonly type: JournalPartyType;
  readonly id: string;
  readonly label: string;
}

interface Line {
  readonly key: number;
  accountId: string;
  debit: string;
  credit: string;
  narration: string;
  /** `TYPE:id`, or '' for no party. */
  party: string;
}

const blank = (key: number): Line => ({ key, accountId: '', debit: '', credit: '', narration: '', party: '' });

/** A ready-made entry: accounts, sides and parties; the amount is typed once. */
export interface JournalTemplate {
  readonly label: string;
  readonly narration: string;
  readonly lines: readonly { accountId: string; side: 'DEBIT' | 'CREDIT'; party: string }[];
  readonly hint?: string;
}
const partyKey = (p: { type: string; id: string }) => `${p.type}:${p.id}`;
const TYPE_LABEL: Record<JournalPartyType, string> = {
  CUSTOMER: 'Customer', SUPPLIER: 'Supplier', FINANCE_COMPANY: 'Finance co.',
};

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
export function JournalEntryForm({
  accounts,
  defaultAccountId,
  parties = [],
  defaultParty,
  defaultNarration = '',
  templates = [],
  narrations,
  initialLines,
  afterPost = 'navigate',
  onDone,
}: {
  readonly accounts: readonly AccountOption[];
  /** Pre-fills the first line — used when entering from an account's ledger. */
  readonly defaultAccountId?: string;
  /**
   * Who a line can be held against. A receivable, payable or finance line
   * without one moves the control account but no one's ledger, so the party's
   * statement and the tie-out stop agreeing.
   */
  readonly parties?: readonly PartyOption[];
  /** Pre-fills the first line's party — entering from a customer's page. */
  readonly defaultParty?: PartyOption;
  readonly defaultNarration?: string;
  readonly templates?: readonly JournalTemplate[];
  /** Narration templates (0091), offered as suggestions; still editable. */
  readonly narrations?: readonly string[];
  /** Pre-filled lines — correcting a posted entry starts from its lines. */
  readonly initialLines?: readonly { accountId: string; debit: number; credit: number; narration: string | null; party: string }[];
  /**
   * 'navigate' opens the new entry; 'stay' refreshes in place, which is what an
   * inline panel on a ledger wants — the point of entering there is to see the
   * line appear in the ledger you were already reading.
   */
  readonly afterPost?: 'navigate' | 'stay';
  readonly onDone?: () => void;
}) {
  const router = useRouter();
  const [pending, startTransition] = React.useTransition();
  const [error, setError] = React.useState<string | null>(null);

  const [entryDate, setEntryDate] = React.useState(() => new Date().toISOString().slice(0, 10));
  const [narration, setNarration] = React.useState(defaultNarration);
  const firstLine = (key: number): Line => ({
    ...blank(key),
    accountId: defaultAccountId ?? '',
    party: defaultParty ? partyKey(defaultParty) : '',
  });
  const [lines, setLines] = React.useState<Line[]>(() =>
    initialLines && initialLines.length > 0
      ? initialLines.map((l, i) => ({
          key: i + 1, accountId: l.accountId, narration: l.narration ?? '', party: l.party,
          debit: l.debit > 0 ? String(l.debit) : '', credit: l.credit > 0 ? String(l.credit) : '',
        }))
      : [firstLine(1), blank(2)]);
  const nextKey = React.useRef(Math.max(3, (initialLines?.length ?? 0) + 1));
  const [formKey, setFormKey] = React.useState(0);
  const [hint, setHint] = React.useState<string | null>(null);

  const applyTemplate = (t: JournalTemplate) => {
    setNarration(t.narration);
    setHint(t.hint ?? null);
    setLines(t.lines.map((l) => ({ ...blank(nextKey.current++), accountId: l.accountId, party: l.party })));
    // The pickers keep their own state; a new key makes them start from these values.
    setFormKey((k) => k + 1);
  };

  const idempotency = useIdempotencyKey('manual-journal');

  const options = React.useMemo(
    () => accounts.map((a) => ({ id: a.id, label: `${a.code} · ${a.name}` })),
    [accounts],
  );
  const partyOptions = React.useMemo(() => {
    const all = defaultParty && !parties.some((p) => partyKey(p) === partyKey(defaultParty))
      ? [defaultParty, ...parties] : [...parties];
    return all.map((p) => ({ id: partyKey(p), label: `${TYPE_LABEL[p.type]} · ${p.label}` }));
  }, [parties, defaultParty]);
  const showParty = partyOptions.length > 0;

  const totals = lines.reduce(
    (sum, l) => ({
      debit: sum.debit + (Number(l.debit) || 0),
      credit: sum.credit + (Number(l.credit) || 0),
    }),
    { debit: 0, credit: 0 },
  );
  const difference = Math.round((totals.debit - totals.credit) * 100) / 100;
  const balanced = difference === 0 && totals.debit > 0;

  // On a two-line entry the other line mirrors the amount typed, on the other
  // side — the entry is balanced as soon as one figure is in.
  const update = (key: number, patch: Partial<Line>) =>
    setLines((current) => {
      const next = current.map((l) => (l.key === key ? { ...l, ...patch } : l));
      if (next.length === 2 && ('debit' in patch || 'credit' in patch)) {
        const other = next.find((l) => l.key !== key)!;
        const amount = patch.debit || patch.credit || '';
        const side = patch.debit ? 'credit' : 'debit';
        return next.map((l) => (l.key === other.key ? { ...l, debit: '', credit: '', [side]: amount } : l));
      }
      return next;
    });

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
            partyType: l.party ? (l.party.split(':')[0] as JournalPartyType) : null,
            partyId: l.party ? l.party.split(':')[1] : null,
          })),
        idempotencyKey: idempotency.key(),
      });

      if (!result.ok) {
        setError(result.error ?? 'The entry could not be posted.');
        return;
      }
      idempotency.renew();

      if (afterPost === 'navigate') {
        // Submitted for approval rather than posted (0081): there is no journal
        // yet, so show the queue it is waiting in.
        router.push(result.id ? `/accounting/journals/${result.id}` : '/accounting/approvals');
        router.refresh();
        return;
      }

      // Reset for the next line rather than clearing to nothing: someone adding
      // entries against one account is usually adding several.
      setLines([firstLine(nextKey.current++), blank(nextKey.current++)]);
      setNarration(defaultNarration);
      setHint(null);
      setFormKey((k) => k + 1);
      router.refresh();
      onDone?.();
    });
  };

  return (
    <div className="space-y-4">
      {error && (
        <div role="alert" className="rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
          {error}
        </div>
      )}

      {templates.length > 0 && (
        <div className="flex flex-wrap items-center gap-2">
          <span className="text-xs font-medium text-ink-500">Template:</span>
          {templates.map((t) => (
            <Button key={t.label} type="button" size="sm" variant="secondary" onClick={() => applyTemplate(t)}>
              {t.label}
            </Button>
          ))}
          {hint && <span className="text-xs text-warning-700">{hint}</span>}
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
              list={narrations?.length ? 'journal-narrations' : undefined}
            />
            {narrations && narrations.length > 0 && (
              <datalist id="journal-narrations">
                {narrations.map((n) => <option key={n} value={n} />)}
              </datalist>
            )}
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
                {['Account', ...(showParty ? ['Party'] : []), 'Narration', 'Debit', 'Credit', ''].map((h) => (
                  <th key={h} scope="col" className="px-3 py-2.5 text-left text-[11px] font-semibold uppercase tracking-wide text-ink-500">
                    {h}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {lines.map((line) => (
                <tr key={`${formKey}-${line.key}`} className="border-b border-ink-50">
                  <td className="min-w-64 px-3 py-2">
                    <SearchSelect
                      name={`account-${line.key}`}
                      options={options}
                      defaultValue={line.accountId}
                      placeholder="Search the chart of accounts…"
                      onChange={(id) => update(line.key, { accountId: id })}
                    />
                  </td>
                  {showParty && (
                    <td className="min-w-56 px-3 py-2">
                      <SearchSelect
                        name={`party-${line.key}`}
                        options={partyOptions}
                        defaultValue={line.party}
                        placeholder="No party"
                        onChange={(id) => update(line.key, { party: id })}
                      />
                    </td>
                  )}
                  <td className="px-3 py-2">
                    <Input
                      value={line.narration}
                      onChange={(e) => update(line.key, { narration: e.target.value })}
                      placeholder="Optional"
                    />
                  </td>
                  <td className="px-3 py-2">
                    <AmountInput
                      className="w-32" aria-label="Debit"
                      value={line.debit}
                      // A line is one side or the other; typing in one clears
                      // the other rather than letting both carry a figure.
                      onValueChange={(v) => update(line.key, { debit: v, credit: '' })}
                    />
                  </td>
                  <td className="px-3 py-2">
                    <AmountInput
                      className="w-32" aria-label="Credit"
                      value={line.credit}
                      onValueChange={(v) => update(line.key, { credit: v, debit: '' })}
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
                <td className="px-3 py-2 text-xs font-medium text-ink-600" colSpan={showParty ? 3 : 2}>Total</td>
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
