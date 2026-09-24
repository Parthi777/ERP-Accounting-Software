import Link from 'next/link';
import type { Metadata } from 'next';

import { getItcAdjustments, getRule37Candidates } from '@/server/services/gst/gst-compliance-service';
import { itcAdjustmentAction } from '@/server/services/gst/gst-compliance-actions';
import { requireTenantContext } from '@/server/auth/tenant-context';
import { PageHeader } from '@/components/data-table/data-table';
import { Panel, PanelContent, PanelHeader, PanelTitle, SolidPanel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { ActionForm } from '@/components/forms/action-form';
import { formatINR, fromRupees } from '@/lib/money';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'ITC Reversals' };
export const dynamic = 'force-dynamic';

const RULES = [
  { value: 'RULE_37', label: 'Rule 37 — supplier unpaid after 180 days' },
  { value: 'RULE_42', label: 'Rule 42 — common credit on inputs' },
  { value: 'RULE_43', label: 'Rule 43 — common credit on capital goods' },
  { value: 'SECTION_17_5', label: 's.17(5) — blocked credit' },
  { value: 'OTHER', label: 'Other' },
];

/**
 * Input tax credit reversed and re-claimed — checklist §08. Each adjustment
 * posts Input GST ⇄ 5990 Input Tax Credit Reversed; a re-claim can never exceed
 * what was reversed under the same rule (and bill). Rule 37 lists the bills
 * whose credit is due for reversal today.
 */
export default async function ItcPage() {
  const context = await requireTenantContext();
  const canManage = context.permissions.has('gst.itc.manage');
  const today = new Date().toISOString().slice(0, 10);
  const [rows, due] = await Promise.all([getItcAdjustments(), getRule37Candidates(today)]);
  const branchOptions = context.accessibleBranches.map((b) => ({ value: b.id, label: b.name }));
  const th = 'px-4 py-2.5 text-[11px] font-semibold uppercase tracking-wide text-ink-500';

  return (
    <div className="space-y-5">
      <PageHeader title="ITC Reversals" description="Input tax credit taken back, and given back, with the rule for each." count={rows.length} />

      <SolidPanel className="overflow-hidden">
        <div className="border-b border-ink-100 px-4 py-3">
          <h2 className="text-sm font-semibold text-ink-900">Rule 37: bills unpaid after 180 days</h2>
          <p className="text-xs text-ink-500">Payments are applied to a supplier&rsquo;s oldest bills first. Credit on what is still unpaid must be reversed until it is paid, then re-claimed.</p>
        </div>
        <table className="w-full border-collapse text-sm">
          <thead><tr>
            <th className={`${th} text-left`}>Bill</th><th className={`${th} text-left`}>Supplier</th>
            <th className={`${th} text-right`}>Days</th><th className={`${th} text-right`}>Unpaid</th>
            <th className={`${th} text-right`}>Credit to reverse</th>{canManage && <th className={th} />}
          </tr></thead>
          <tbody>
            {due.length === 0 ? (
              <tr><td colSpan={6} className="px-4 py-8 text-center text-ink-400">No credit is due for reversal under rule 37.</td></tr>
            ) : due.map((d) => (
              <tr key={d.billId} className="border-t border-ink-100 align-top">
                <td className="px-4 py-2"><Link href={`/purchases/${d.billId}`} className="font-mono text-xs text-brand-700 hover:underline">{d.billNumber}</Link>
                  <span className="block text-[11px] text-ink-400">{d.supplierBillNumber} · {formatDate(d.billDate)}</span></td>
                <td className="px-4 py-2">{d.supplier}</td>
                <td className="numeric px-4 py-2">{d.days}</td>
                <td className="numeric px-4 py-2">{formatINR(d.unpaid)}</td>
                <td className="numeric px-4 py-2 font-medium">{formatINR(fromRupees(d.cgst + d.sgst + d.igst))}</td>
                {canManage && (
                  <td className="px-4 py-2">
                    <ActionForm action={itcAdjustmentAction} submitLabel="Reverse" columns={1}
                      confirm={`Reverse the credit on ${d.billNumber}? It posts to 5990 today.`}
                      fixed={{ direction: 'REVERSAL', rule: 'RULE_37', branchId: d.branchId, billId: d.billId,
                               cgst: String(d.cgst), sgst: String(d.sgst), igst: String(d.igst), date: today }}
                      fields={[{ name: 'note', label: 'Note', defaultValue: 'Supplier unpaid after 180 days', required: true }]} />
                  </td>
                )}
              </tr>
            ))}
          </tbody>
        </table>
      </SolidPanel>

      {canManage && (
        <Panel>
          <PanelHeader><PanelTitle>Reverse or re-claim credit</PanelTitle></PanelHeader>
          <PanelContent>
            <ActionForm action={itcAdjustmentAction} submitLabel="Post" columns={4}
              confirm="Post this adjustment to input tax?" fields={[
                { name: 'direction', label: 'Adjustment', type: 'select', required: true, defaultValue: 'REVERSAL', options: [
                  { value: 'REVERSAL', label: 'Reverse credit' }, { value: 'RECLAIM', label: 'Re-claim credit' },
                ] },
                { name: 'rule', label: 'Under', type: 'select', required: true, defaultValue: 'RULE_42', options: RULES, wide: true },
                { name: 'branchId', label: 'Branch', type: 'select', required: true, options: branchOptions, defaultValue: context.activeBranch?.id },
                { name: 'date', label: 'Date', type: 'date', required: true, defaultValue: today },
                { name: 'cgst', label: 'CGST (₹)', type: 'number', step: '0.01', defaultValue: '0' },
                { name: 'sgst', label: 'SGST (₹)', type: 'number', step: '0.01', defaultValue: '0' },
                { name: 'igst', label: 'IGST (₹)', type: 'number', step: '0.01', defaultValue: '0' },
                { name: 'note', label: 'Working / reason', required: true, wide: true,
                  hint: 'For rule 42/43, the apportionment: exempt turnover ÷ total turnover × common credit.' },
              ]} />
          </PanelContent>
        </Panel>
      )}

      <SolidPanel className="overflow-hidden">
        <table className="w-full border-collapse text-sm">
          <thead><tr>
            <th className={`${th} text-left`}>Date</th><th className={`${th} text-left`}>Adjustment</th>
            <th className={`${th} text-left`}>Bill</th><th className={`${th} text-left`}>Note</th>
            <th className={`${th} text-right`}>Amount</th>
          </tr></thead>
          <tbody>
            {rows.length === 0 ? (
              <tr><td colSpan={5} className="px-4 py-10 text-center text-ink-400">No adjustments yet.</td></tr>
            ) : rows.map((r) => (
              <tr key={r.id} className="border-t border-ink-100">
                <td className="px-4 py-2 text-ink-600">{formatDate(r.date)}</td>
                <td className="px-4 py-2">
                  <Badge variant={r.direction === 'REVERSAL' ? 'warning' : 'positive'}>{r.direction === 'REVERSAL' ? 'Reversed' : 'Re-claimed'}</Badge>
                  <span className="ml-2 text-xs text-ink-500">{r.rule.replace(/_/g, ' ')}</span>
                </td>
                <td className="px-4 py-2 font-mono text-xs">{r.billNumber ?? '—'}</td>
                <td className="px-4 py-2 text-ink-700">
                  {r.journalId ? <Link href={`/accounting/journals/${r.journalId}`} className="hover:underline">{r.note}</Link> : r.note}
                </td>
                <td className="numeric px-4 py-2 font-medium">{formatINR(r.total)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </SolidPanel>
    </div>
  );
}
