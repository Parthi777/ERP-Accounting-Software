import type { Metadata } from 'next';
import Link from 'next/link';
import { notFound } from 'next/navigation';
import { ArrowLeft, Lock } from 'lucide-react';

import { getPurchaseReturn } from '@/server/services/purchases/purchase-return-service';
import { requirePermission, hasPermission } from '@/server/auth/tenant-context';
import { PurchaseReturnReverse } from '@/components/purchases/purchase-return-reverse';
import { DataTable, type Column } from '@/components/data-table/data-table';
import { Panel, PanelContent, PanelHeader, PanelTitle } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { add, formatINR } from '@/lib/money';
import { formatDate, formatDateTime } from '@/lib/format';
import type { PurchaseReturnLine } from '@/server/services/purchases/purchase-return-service';

export const metadata: Metadata = { title: 'Purchase return' };
export const dynamic = 'force-dynamic';

const TONE: Record<string, 'neutral' | 'info' | 'positive' | 'danger'> = {
  DRAFT: 'info',
  POSTED: 'positive',
  CANCELLED: 'danger',
};

export default async function Page({ params }: { params: Promise<{ id: string }> }) {
  const context = await requirePermission('purchases.view');
  const { id } = await params;

  const note = await getPurchaseReturn(id);
  if (!note) {
    notFound();
  }

  const canReverse = hasPermission(context, 'purchases.cancel') && note.status === 'POSTED';

  const columns: Column<PurchaseReturnLine>[] = [
    { key: 'no', header: '#', render: (line) => line.lineNumber },
    {
      key: 'item',
      header: 'Item',
      render: (line) => (
        <span>
          <span className="block text-ink-800">{line.description}</span>
          <span className="block font-mono text-[11px] text-ink-400">
            {line.chassisNo ?? line.itemCode}
            {line.source ? ` · ${line.source === 'LOCAL' ? 'Local' : 'Company'}` : ''}
          </span>
        </span>
      ),
    },
    { key: 'qty', header: 'Qty', numeric: true, render: (line) => line.quantity },
    { key: 'rate', header: 'Rate', numeric: true, render: (line) => formatINR(line.unitRate) },
    { key: 'taxable', header: 'Goods', numeric: true, render: (line) => formatINR(line.taxableValue) },
    {
      key: 'tax',
      header: 'GST',
      numeric: true,
      render: (line) => {
        const tax = add(line.cgstAmount, line.sgstAmount, line.igstAmount);
        return tax > 0 ? formatINR(tax) : <span className="text-ink-300">—</span>;
      },
    },
    {
      key: 'total',
      header: 'Credit',
      numeric: true,
      render: (line) => <span className="font-medium text-ink-900">{formatINR(line.totalAmount)}</span>,
    },
  ];

  return (
    <div>
      <Button variant="ghost" size="sm" asChild className="-ml-2 mb-2">
        <Link href="/purchases/returns"><ArrowLeft aria-hidden />Purchase returns</Link>
      </Button>

      <div className="mb-4 flex flex-wrap items-start justify-between gap-3">
        <div>
          <div className="flex flex-wrap items-center gap-2">
            <h1 className="font-mono text-xl font-bold tracking-tight text-ink-900">{note.returnNumber}</h1>
            <Badge variant={TONE[note.status] ?? 'neutral'}>
              {note.status === 'CANCELLED' ? 'REVERSED' : note.status}
            </Badge>
            {note.status === 'POSTED' && (
              <span className="flex items-center gap-1 text-xs text-ink-500">
                <Lock className="size-3.5" aria-hidden />
                Immutable
              </span>
            )}
          </div>
          <p className="mt-0.5 text-sm text-ink-500">
            Back to {note.supplierName} off{' '}
            <Link href={`/purchases/${note.billId}`} className="font-mono text-brand-600 hover:underline">
              {note.billNumber}
            </Link>{' '}
            · {formatDate(note.returnDate)} · {note.branchName}
          </p>
        </div>

        <div className="flex items-center gap-2">
          {note.journalEntryId && (
            <Button variant="secondary" size="sm" asChild>
              <Link href={`/accounting/journals/${note.journalEntryId}`}>Journal entry</Link>
            </Button>
          )}
          {canReverse && (
            <PurchaseReturnReverse
              returnId={note.id}
              billId={note.billId}
              returnNumber={note.returnNumber}
            />
          )}
        </div>
      </div>

      <div className="grid gap-4 lg:grid-cols-3">
        <div className="space-y-4 lg:col-span-2">
          <DataTable
            columns={columns}
            rows={[...note.lines]}
            getRowKey={(line) => line.id}
            emptyMessage="This note has no lines."
            caption={`Lines on ${note.returnNumber}`}
          />

          <Panel className="p-4">
            <h2 className="text-sm font-semibold text-ink-900">Why</h2>
            <p className="mt-1 whitespace-pre-line text-sm text-ink-700">{note.reason}</p>
            {note.notes && (
              <p className="mt-3 whitespace-pre-line rounded-lg border border-ink-100 bg-ink-50 px-3 py-2 text-xs text-ink-600">
                {note.notes}
              </p>
            )}
          </Panel>
        </div>

        <div className="space-y-4">
          <Panel>
            <PanelHeader><PanelTitle>Summary</PanelTitle></PanelHeader>
            <PanelContent>
              <dl className="space-y-2.5">
                <Row label="Goods returned" value={formatINR(note.taxableValue)} />
                {note.cgstAmount > 0 && <Row label="Input CGST reversed" value={formatINR(note.cgstAmount)} />}
                {note.sgstAmount > 0 && <Row label="Input SGST reversed" value={formatINR(note.sgstAmount)} />}
                {note.igstAmount > 0 && <Row label="Input IGST reversed" value={formatINR(note.igstAmount)} />}
                <div className="border-t border-ink-200 pt-2.5">
                  <Row label="Off the supplier's account" value={formatINR(note.totalAmount)} strong />
                </div>
              </dl>
              <p className="mt-3 text-[11px] text-ink-400">
                {note.status === 'POSTED'
                  ? 'Open on the supplier ledger as a debit until it is set against a bill in Accounting → Supplier Ledger.'
                  : 'Reversed: this note no longer affects the supplier’s balance or the stock.'}
              </p>
            </PanelContent>
          </Panel>

          <Panel>
            <PanelHeader><PanelTitle>Note</PanelTitle></PanelHeader>
            <PanelContent>
              <dl className="space-y-2.5">
                <Row label="Supplier" value={note.supplierName} />
                <Row label="Supplier code" value={note.supplierCode} />
                <Row label="Their bill" value={note.supplierBillNumber} />
                <Row label="Their credit note" value={note.supplierRef ?? '—'} />
                <Row label="Return date" value={formatDate(note.returnDate)} />
                {note.postedAt && <Row label="Posted" value={formatDateTime(note.postedAt)} />}
              </dl>
            </PanelContent>
          </Panel>
        </div>
      </div>
    </div>
  );
}

function Row({
  label,
  value,
  strong = false,
}: {
  readonly label: string;
  readonly value: string;
  readonly strong?: boolean;
}) {
  return (
    <div className="flex items-baseline justify-between gap-3">
      <dt className="text-xs text-ink-500">{label}</dt>
      <dd className={strong ? 'numeric text-base font-bold text-ink-900' : 'numeric text-sm text-ink-800'}>
        {value}
      </dd>
    </div>
  );
}
