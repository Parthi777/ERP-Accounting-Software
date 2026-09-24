import Link from 'next/link';
import type { Metadata } from 'next';

import { getGstNotes, getNoteAccounts, getNoteOriginals } from '@/server/services/gst/gst-compliance-service';
import { cancelNoteAction, issueNoteAction } from '@/server/services/gst/gst-compliance-actions';
import { requireTenantContext } from '@/server/auth/tenant-context';
import { PageHeader } from '@/components/data-table/data-table';
import { Panel, PanelContent, PanelHeader, PanelTitle, SolidPanel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { ActionForm } from '@/components/forms/action-form';
import { formatINR } from '@/lib/money';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'Credit & Debit Notes' };
export const dynamic = 'force-dynamic';

const REASONS = [
  { value: 'DISCOUNT', label: 'Discount after sale' },
  { value: 'PRICE_REVISION', label: 'Price revision' },
  { value: 'SHORT_SUPPLY', label: 'Short supply' },
  { value: 'DEFICIENCY', label: 'Deficiency in service' },
  { value: 'RATE_CORRECTION', label: 'Tax rate correction' },
  { value: 'OTHER', label: 'Other' },
];

/**
 * Credit and debit notes (s.34) — checklist §05. Issued to a customer against
 * a sale or service invoice, or recorded from a supplier against a purchase
 * bill; each takes the tax mode of the document it amends and posts at once.
 * Returns of goods have their own screens; these are value adjustments.
 */
export default async function GstNotesPage() {
  const context = await requireTenantContext();
  const canManage = context.permissions.has('gst.notes.manage');
  const [notes, originals, accounts] = await Promise.all([
    getGstNotes(),
    canManage ? getNoteOriginals() : Promise.resolve([]),
    canManage ? getNoteAccounts() : Promise.resolve([]),
  ]);
  const th = 'px-4 py-2.5 text-[11px] font-semibold uppercase tracking-wide text-ink-500';

  return (
    <div className="space-y-5">
      <PageHeader title="Credit & Debit Notes"
        description="Value corrections to an invoice or bill after it was issued. Each note carries the original's tax and posts immediately."
        count={notes.length} />

      {canManage && (
        <Panel>
          <PanelHeader><PanelTitle>New note</PanelTitle></PanelHeader>
          <PanelContent>
            <ActionForm action={issueNoteAction} submitLabel="Issue and post" columns={3}
              confirm="Post this note? It changes the party's balance and the GST return; it can only be cancelled, not edited."
              fields={[
                { name: 'noteType', label: 'Note', type: 'select', required: true, defaultValue: 'CREDIT', options: [
                  { value: 'CREDIT', label: 'Credit note (reduces the invoice)' },
                  { value: 'DEBIT', label: 'Debit note (adds to the invoice)' },
                ] },
                { name: 'original', label: 'Against', type: 'select', required: true, wide: true,
                  options: originals.map((o) => ({ value: o.value, label: `${o.party === 'CUSTOMER' ? 'Invoice' : 'Bill'} ${o.label}` })),
                  hint: 'For a supplier bill, record the note the supplier sent you.' },
                { name: 'taxable', label: 'Value before tax (₹)', type: 'number', step: '0.01', required: true },
                { name: 'gstRate', label: 'GST rate (%)', type: 'number', step: '0.01', required: true, defaultValue: '18',
                  hint: 'The rate on the original. IGST or CGST+SGST follows the original.' },
                { name: 'accountId', label: 'Value goes to', type: 'select', required: true, options: accounts,
                  hint: 'e.g. the sales account for a discount allowed; Other Income for a supplier discount.' },
                { name: 'reason', label: 'Reason', type: 'select', required: true, defaultValue: 'DISCOUNT', options: REASONS },
                { name: 'noteDate', label: 'Date', type: 'date', required: true, defaultValue: new Date().toISOString().slice(0, 10) },
                { name: 'hsnSac', label: 'HSN / SAC', placeholder: 'From the original if blank' },
                { name: 'description', label: 'Description', required: true, wide: true },
                { name: 'partyNoteNumber', label: 'Supplier’s note no.', hint: 'Supplier notes only.' },
                { name: 'itcEligible', label: 'Input tax on it is claimable', type: 'checkbox', defaultValue: 'true',
                  hint: 'Supplier notes only: untick if the bill’s credit was blocked.' },
              ]} />
          </PanelContent>
        </Panel>
      )}

      <SolidPanel className="overflow-hidden">
        <div className="table-sticky overflow-auto" style={{ maxHeight: '40rem' }}>
          <table className="w-full border-collapse text-sm">
            <thead><tr>
              <th className={`${th} text-left`}>Note</th><th className={`${th} text-left`}>Party</th>
              <th className={`${th} text-left`}>Against</th><th className={`${th} text-left`}>For</th>
              <th className={`${th} text-right`}>Value</th><th className={`${th} text-right`}>GST</th>
              <th className={`${th} text-right`}>Total</th>{canManage && <th className={th} />}
            </tr></thead>
            <tbody>
              {notes.length === 0 ? (
                <tr><td colSpan={8} className="px-4 py-12 text-center text-ink-400">No notes yet.</td></tr>
              ) : notes.map((n) => (
                <tr key={n.id} className={`border-t border-ink-100 align-top ${n.status === 'CANCELLED' ? 'text-ink-400' : ''}`}>
                  <td className="px-4 py-2">
                    {n.journalId ? <Link href={`/accounting/journals/${n.journalId}`} className="font-mono text-xs font-semibold text-brand-700 hover:underline">{n.number}</Link>
                      : <span className="font-mono text-xs">{n.number}</span>}
                    <span className="mt-1 flex gap-1">
                      <Badge variant={n.noteType === 'CREDIT' ? 'warning' : 'info'}>{n.noteType === 'CREDIT' ? 'Credit' : 'Debit'}</Badge>
                      {n.status === 'CANCELLED' && <Badge variant="neutral">Cancelled</Badge>}
                    </span>
                    <span className="block text-[11px] text-ink-400">{formatDate(n.noteDate)}</span>
                  </td>
                  <td className="px-4 py-2">
                    {n.partyName}
                    <span className="block text-[11px] text-ink-400">{n.partyType === 'CUSTOMER' ? 'Customer' : `Supplier${n.partyNoteNumber ? ` · ${n.partyNoteNumber}` : ''}`}</span>
                  </td>
                  <td className="px-4 py-2 font-mono text-xs">{n.originalNumber}</td>
                  <td className="px-4 py-2 text-ink-700">{n.description}</td>
                  <td className="numeric px-4 py-2">{formatINR(n.taxable)}</td>
                  <td className="numeric px-4 py-2">{formatINR(n.tax)}</td>
                  <td className="numeric px-4 py-2 font-medium">{formatINR(n.total)}</td>
                  {canManage && (
                    <td className="px-4 py-2" style={{ minWidth: '14rem' }}>
                      {n.status === 'POSTED' && (
                        <details>
                          <summary className="cursor-pointer text-xs text-danger-700">Cancel…</summary>
                          <div className="mt-2">
                            <ActionForm action={cancelNoteAction} submitLabel="Cancel note" columns={1}
                              fixed={{ noteId: n.id }} confirm={`Cancel ${n.number}? Its journal is reversed today.`}
                              fields={[{ name: 'reason', label: 'Why', required: true }]} />
                          </div>
                        </details>
                      )}
                    </td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </SolidPanel>
    </div>
  );
}
