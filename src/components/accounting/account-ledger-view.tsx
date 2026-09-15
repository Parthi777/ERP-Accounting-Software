'use client';

import * as React from 'react';
import Link from 'next/link';
import { Plus, X } from 'lucide-react';

import { Panel, SolidPanel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { JournalEntryForm } from '@/components/accounting/journal-entry-form';
import { formatINR, type Paise } from '@/lib/money';
import { formatDate } from '@/lib/format';
import type { AccountLedger } from '@/server/services/accounting/journal-entry-service';

interface AccountOption {
  readonly id: string;
  readonly code: string;
  readonly name: string;
  readonly type: string;
}

/**
 * An account's ledger, with entry in place — spec §41, §43.
 *
 * The reason the form is here rather than only on its own screen: someone
 * reading an account's movements and noticing something missing should be able
 * to add it without losing the page they were reading. Posting refreshes the
 * ledger underneath, so the new line appears where they were already looking.
 *
 * The first line comes pre-filled with the account on screen, because that is
 * the account they are thinking about.
 */
export function AccountLedgerView({
  ledger,
  accounts,
  canPost,
}: {
  readonly ledger: AccountLedger;
  readonly accounts: readonly AccountOption[];
  readonly canPost: boolean;
}) {
  const [adding, setAdding] = React.useState(false);
  const account = ledger.account;

  if (!account) return null;

  // A debit-normal account reads naturally as a positive debit balance; a
  // credit-normal one is the mirror, and showing it as negative would have the
  // accountant mentally flipping every figure.
  const creditNormal = account.type === 'LIABILITY' || account.type === 'EQUITY' || account.type === 'INCOME';
  const present = (value: Paise) => formatINR((creditNormal ? -value : value) as Paise);
  const side = creditNormal ? 'Cr' : 'Dr';

  return (
    <div className="space-y-4">
      <div className="grid gap-3 sm:grid-cols-4">
        {[
          { label: 'Opening', value: present(ledger.opening) },
          { label: 'Debit in period', value: formatINR(ledger.debit) },
          { label: 'Credit in period', value: formatINR(ledger.credit) },
          { label: `Closing (${side})`, value: present(ledger.closing) },
        ].map((card) => (
          <Panel key={card.label} className="p-4">
            <p className="text-xs text-ink-500">{card.label}</p>
            <p className="numeric mt-0.5 text-lg font-semibold text-ink-900">{card.value}</p>
          </Panel>
        ))}
      </div>

      <div className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <h2 className="text-base font-semibold text-ink-900">
            <span className="font-mono text-sm text-ink-500">{account.code}</span> {account.name}
          </h2>
          <p className="text-xs text-ink-500">{account.type}</p>
        </div>

        {canPost && !adding && (
          <Button size="sm" onClick={() => setAdding(true)}>
            <Plus aria-hidden />
            Add entry
          </Button>
        )}
        {adding && (
          <Button variant="secondary" size="sm" onClick={() => setAdding(false)}>
            <X aria-hidden />
            Close
          </Button>
        )}
      </div>

      {adding && (
        <div className="rounded-xl border border-brand-200 bg-brand-50/40 p-3">
          <p className="mb-3 text-xs text-ink-600">
            The first line is set to <strong>{account.name}</strong>. Posting adds it to the ledger
            below — a posted entry cannot be edited afterwards, so check it before posting (spec §23).
          </p>
          <JournalEntryForm
            accounts={accounts}
            defaultAccountId={account.id}
            afterPost="stay"
          />
        </div>
      )}

      <SolidPanel className="overflow-hidden">
        <div className="table-sticky overflow-auto" style={{ maxHeight: '36rem' }}>
          <table className="w-full border-collapse text-sm">
            <caption className="sr-only">Account ledger</caption>
            <thead>
              <tr className="bg-ink-50">
                {['Date', 'Entry', 'Particulars', 'Contra', 'Debit', 'Credit', 'Balance'].map((h, i) => (
                  <th
                    key={h}
                    scope="col"
                    className={`whitespace-nowrap px-3 py-2.5 text-[11px] font-semibold uppercase tracking-wide text-ink-500 ${i >= 4 ? 'text-right' : 'text-left'}`}
                  >
                    {h}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {ledger.lines.length === 0 && (
                <tr>
                  <td colSpan={7} className="px-3 py-10 text-center text-sm text-ink-500">
                    No movements in this period. The opening balance shown is carried forward.
                  </td>
                </tr>
              )}

              {ledger.lines.map((line, index) => (
                <tr key={`${line.journalEntryId}-${index}`} className="border-t border-ink-100">
                  <td className="whitespace-nowrap px-3 py-2 text-ink-600">{formatDate(line.entryDate)}</td>
                  <td className="whitespace-nowrap px-3 py-2">
                    <Link
                      href={`/accounting/journals/${line.journalEntryId}`}
                      className="font-mono text-xs text-brand-700 hover:underline"
                    >
                      {line.entryNumber}
                    </Link>
                    {line.status === 'REVERSED' && (
                      <Badge variant="warning" className="ml-1.5">Reversed</Badge>
                    )}
                  </td>
                  <td className="px-3 py-2 text-ink-700">{line.narration ?? '—'}</td>
                  <td className="px-3 py-2 text-ink-500">{line.contra ?? '—'}</td>
                  <td className="numeric px-3 py-2 text-right">
                    {line.debit > 0 ? formatINR(line.debit) : '—'}
                  </td>
                  <td className="numeric px-3 py-2 text-right">
                    {line.credit > 0 ? formatINR(line.credit) : '—'}
                  </td>
                  <td className="numeric px-3 py-2 text-right font-medium">
                    {present(line.runningBalance)}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </SolidPanel>
    </div>
  );
}
