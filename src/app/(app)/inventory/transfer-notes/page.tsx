import Link from 'next/link';
import type { Metadata } from 'next';

import { getTransferNotes } from '@/server/services/stock-condition/stock-condition-service';
import { PageHeader } from '@/components/data-table/data-table';
import { SolidPanel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { formatINR } from '@/lib/money';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'Transfer Notes' };
export const dynamic = 'force-dynamic';

/**
 * Delivery challans and branch tax invoices — checklist §06, §07 (0083).
 * Issued by every stock or vehicle transfer: a challan between branches of one
 * GSTIN, a tax invoice between two.
 */
export default async function TransferNotesPage() {
  const notes = await getTransferNotes();
  const th = 'px-4 py-2.5 text-[11px] font-semibold uppercase tracking-wide text-ink-500';
  return (
    <div className="space-y-5">
      <PageHeader title="Transfer Notes" description="The document behind every branch transfer: a delivery challan within one GSTIN, a tax invoice between two." count={notes.length} />
      <SolidPanel className="overflow-hidden">
        <div className="table-sticky overflow-auto" style={{ maxHeight: '42rem' }}>
          <table className="w-full border-collapse text-sm">
            <thead><tr>
              <th className={`${th} text-left`}>Note</th><th className={`${th} text-left`}>Date</th>
              <th className={`${th} text-left`}>From → To</th><th className={`${th} text-left`}>What</th>
              <th className={`${th} text-right`}>Value</th><th className={`${th} text-right`}>GST</th>
            </tr></thead>
            <tbody>
              {notes.length === 0 ? (
                <tr><td colSpan={6} className="px-4 py-12 text-center text-ink-400">No transfers yet.</td></tr>
              ) : notes.map((n) => (
                <tr key={n.id} className="border-t border-ink-100">
                  <td className="px-4 py-2">
                    {n.journalId ? <Link href={`/accounting/journals/${n.journalId}`} className="font-mono text-xs font-semibold text-brand-700 hover:underline">{n.number}</Link>
                      : <span className="font-mono text-xs">{n.number}</span>}
                    <Badge className="ml-2" variant={n.kind === 'TAX_INVOICE' ? 'warning' : 'info'}>
                      {n.kind === 'TAX_INVOICE' ? 'Tax invoice' : 'Delivery challan'}
                    </Badge>
                  </td>
                  <td className="px-4 py-2 text-ink-600">{formatDate(n.date)}</td>
                  <td className="px-4 py-2 text-ink-700">{n.from} → {n.to}</td>
                  <td className="px-4 py-2 text-ink-700">{n.description} × {n.quantity}</td>
                  <td className="numeric px-4 py-2">{formatINR(n.taxable)}</td>
                  <td className="numeric px-4 py-2">{n.tax ? formatINR(n.tax) : '—'}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </SolidPanel>
    </div>
  );
}
