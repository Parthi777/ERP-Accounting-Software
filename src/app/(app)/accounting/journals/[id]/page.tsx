import type { Metadata } from 'next';
import Link from 'next/link';
import { notFound } from 'next/navigation';
import { ArrowLeft, Lock } from 'lucide-react';

import { getJournalDetail } from '@/server/services/accounting/accounting-service';
import { Panel, PanelContent, PanelHeader, PanelTitle, SolidPanel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { add, formatINR, fromDb, ZERO, type Paise } from '@/lib/money';
import { formatDate, formatDateTime } from '@/lib/format';

export const metadata: Metadata = { title: 'Journal Entry' };
export const dynamic = 'force-dynamic';

export default async function JournalDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const detail = await getJournalDetail(id);

  if (!detail) {
    notFound();
  }

  const { entry, lines } = detail;
  const totalDebit = lines.reduce<Paise>((s, l) => add(s, l.debit), ZERO);
  const totalCredit = lines.reduce<Paise>((s, l) => add(s, l.credit), ZERO);

  return (
    <div>
      <Button variant="ghost" size="sm" asChild className="-ml-2 mb-2">
        <Link href="/accounting/journals">
          <ArrowLeft aria-hidden />
          All journal entries
        </Link>
      </Button>

      <div className="mb-4 flex flex-wrap items-start justify-between gap-3">
        <div>
          <div className="flex items-center gap-2">
            <h1 className="font-mono text-xl font-bold tracking-tight text-ink-900">
              {entry.entry_number}
            </h1>
            <Badge variant={entry.status === 'POSTED' ? 'positive' : entry.status === 'REVERSED' ? 'warning' : 'neutral'}>
              {entry.status}
            </Badge>
            <Badge variant="info">{entry.source_module}</Badge>
          </div>
          <p className="mt-0.5 text-sm text-ink-500">{entry.narration ?? 'No narration'}</p>
        </div>
        {entry.status !== 'DRAFT' && (
          <span className="flex items-center gap-1.5 rounded-lg border border-ink-200 bg-ink-50 px-3 py-1.5 text-xs text-ink-600">
            <Lock className="size-3.5" aria-hidden />
            Immutable — corrections are posted as reversals
          </span>
        )}
      </div>

      <SolidPanel className="mb-4 overflow-hidden">
        <table className="w-full border-collapse text-sm">
          <caption className="sr-only">Journal lines</caption>
          <thead>
            <tr className="bg-ink-50">
              <th scope="col" className="px-4 py-2.5 text-left text-[11px] font-semibold uppercase tracking-wide text-ink-500">#</th>
              <th scope="col" className="px-4 py-2.5 text-left text-[11px] font-semibold uppercase tracking-wide text-ink-500">Account</th>
              <th scope="col" className="px-4 py-2.5 text-left text-[11px] font-semibold uppercase tracking-wide text-ink-500">Narration</th>
              <th scope="col" className="px-4 py-2.5 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">Debit</th>
              <th scope="col" className="px-4 py-2.5 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">Credit</th>
            </tr>
          </thead>
          <tbody>
            {lines.map((line) => (
              <tr key={line.lineNumber} className="border-t border-ink-100">
                <td className="px-4 py-2 text-xs text-ink-400">{line.lineNumber}</td>
                <td className="px-4 py-2">
                  <span className="mr-2 font-mono text-xs text-ink-400">{line.accountCode}</span>
                  <span className="text-ink-800">{line.accountName}</span>
                  {line.partyType && <Badge variant="neutral" className="ml-2">{line.partyType}</Badge>}
                </td>
                <td className="px-4 py-2 text-ink-600">{line.narration ?? '—'}</td>
                <td className="numeric px-4 py-2">{line.debit === 0 ? '—' : formatINR(line.debit)}</td>
                <td className="numeric px-4 py-2">{line.credit === 0 ? '—' : formatINR(line.credit)}</td>
              </tr>
            ))}
          </tbody>
          <tfoot>
            <tr className="border-t-2 border-ink-300 bg-ink-50 font-semibold">
              <td colSpan={3} className="px-4 py-3 text-ink-900">Total</td>
              <td className="numeric px-4 py-3 text-ink-900">{formatINR(totalDebit)}</td>
              <td className="numeric px-4 py-3 text-ink-900">{formatINR(totalCredit)}</td>
            </tr>
          </tfoot>
        </table>
      </SolidPanel>

      <Panel>
        <PanelHeader><PanelTitle>Entry details</PanelTitle></PanelHeader>
        <PanelContent>
          <dl className="grid gap-x-8 gap-y-4 sm:grid-cols-3">
            <Detail label="Entry date" value={formatDate(entry.entry_date)} />
            <Detail label="Posted at" value={entry.posted_at ? formatDateTime(entry.posted_at) : '—'} />
            <Detail label="Source document" value={entry.source_document_type ?? '—'} />
            <Detail label="Total debit" value={formatINR(fromDb(entry.total_debit))} />
            <Detail label="Total credit" value={formatINR(fromDb(entry.total_credit))} />
            <Detail label="Idempotency key" value={entry.idempotency_key ?? '—'} />
            {entry.reversal_reason && <Detail label="Reversal reason" value={entry.reversal_reason} />}
          </dl>

          {entry.reversal_of_id && (
            <p className="mt-4 text-sm text-ink-600">
              This entry reverses{' '}
              <Link href={`/accounting/journals/${entry.reversal_of_id}`} className="text-brand-600 hover:underline">
                the original journal
              </Link>.
            </p>
          )}
          {entry.reversed_by_id && (
            <p className="mt-4 text-sm text-ink-600">
              This entry was reversed by{' '}
              <Link href={`/accounting/journals/${entry.reversed_by_id}`} className="text-brand-600 hover:underline">
                a later journal
              </Link>.
            </p>
          )}
        </PanelContent>
      </Panel>
    </div>
  );
}

function Detail({ label, value }: { readonly label: string; readonly value: string }) {
  return (
    <div>
      <dt className="text-xs font-medium uppercase tracking-wide text-ink-400">{label}</dt>
      <dd className="mt-0.5 text-sm text-ink-900">{value}</dd>
    </div>
  );
}
