import type { Metadata } from 'next';

import { getConditionReport, getStockItems } from '@/server/services/stock-condition/stock-condition-service';
import { markDamagedAction, moveConsignmentAction } from '@/server/services/stock-condition/stock-condition-actions';
import { requireTenantContext } from '@/server/auth/tenant-context';
import { PageHeader } from '@/components/data-table/data-table';
import { Panel, PanelContent, PanelHeader, PanelTitle, SolidPanel } from '@/components/ui/panel';
import { ActionForm } from '@/components/forms/action-form';
import { formatINR } from '@/lib/money';

export const metadata: Metadata = { title: 'Damaged & Consignment' };
export const dynamic = 'force-dynamic';

/**
 * Stock that must not be sold — checklist §06 (0083). Damaged stock leaves the
 * saleable lot at what it will fetch; consignment stock is held, not owned,
 * and carries no value. The sale allocator reads neither.
 */
export default async function DamagedConsignmentPage() {
  const context = await requireTenantContext();
  const [rows, items] = await Promise.all([getConditionReport(), getStockItems()]);
  const canAdjust = context.permissions.has('inventory.stock.adjust');
  const itemOptions = items.map((i) => ({ value: i.id, label: i.label }));
  const branchOptions = context.accessibleBranches.map((b) => ({ value: b.id, label: b.name }));
  const th = 'px-4 py-2.5 text-[11px] font-semibold uppercase tracking-wide text-ink-500';

  return (
    <div className="space-y-5">
      <PageHeader title="Damaged & Consignment" description="Stock kept apart from what can be sold." count={rows.length} />

      {canAdjust && (
        <div className="grid gap-5 lg:grid-cols-2">
          <Panel>
            <PanelHeader><PanelTitle>Mark stock damaged</PanelTitle></PanelHeader>
            <PanelContent>
              <ActionForm action={markDamagedAction} submitLabel="Move to damaged" columns={2}
                confirm="Move this stock out of saleable stock? Any write-down posts now." fields={[
                  { name: 'itemId', label: 'Item', type: 'select', required: true, options: itemOptions, wide: true },
                  { name: 'branchId', label: 'Branch', type: 'select', required: true, options: branchOptions, defaultValue: context.activeBranch?.id },
                  { name: 'source', label: 'From lot', type: 'select', required: true, defaultValue: 'COMPANY',
                    options: [{ value: 'COMPANY', label: 'Company' }, { value: 'LOCAL', label: 'Local' }] },
                  { name: 'quantity', label: 'Quantity', type: 'number', step: '0.001', required: true },
                  { name: 'realisableUnit', label: 'Worth now, per unit (₹)', type: 'number', defaultValue: '0',
                    hint: 'The write-down (cost less this) is charged to 5970 Stock Adjustments.' },
                  { name: 'reason', label: 'What happened', required: true, wide: true },
                ]} />
            </PanelContent>
          </Panel>
          <Panel>
            <PanelHeader><PanelTitle>Consignment stock</PanelTitle></PanelHeader>
            <PanelContent>
              <ActionForm action={moveConsignmentAction} submitLabel="Record" columns={2} fields={[
                { name: 'itemId', label: 'Item', type: 'select', required: true, options: itemOptions, wide: true },
                { name: 'branchId', label: 'Branch', type: 'select', required: true, options: branchOptions, defaultValue: context.activeBranch?.id },
                { name: 'direction', label: 'Movement', type: 'select', required: true, defaultValue: 'RECEIVE',
                  options: [{ value: 'RECEIVE', label: 'Received from consignor' }, { value: 'RETURN', label: 'Returned to consignor' }] },
                { name: 'quantity', label: 'Quantity', type: 'number', step: '0.001', required: true },
                { name: 'reference', label: 'Consignor reference', required: true,
                  hint: 'Held at nil value, not sold by the counter. To sell it, buy it in on a purchase bill.' },
              ]} />
            </PanelContent>
          </Panel>
        </div>
      )}

      <SolidPanel className="overflow-hidden">
        <table className="w-full border-collapse text-sm">
          <thead><tr>
            <th className={`${th} text-left`}>Item</th><th className={`${th} text-left`}>Branch</th>
            <th className={`${th} text-right`}>Damaged</th><th className={`${th} text-right`}>Damaged value</th>
            <th className={`${th} text-right`}>On consignment</th>
          </tr></thead>
          <tbody>
            {rows.length === 0 ? (
              <tr><td colSpan={5} className="px-4 py-12 text-center text-ink-400">No damaged or consignment stock.</td></tr>
            ) : rows.map((r) => (
              <tr key={`${r.itemId}-${r.branch}`} className="border-t border-ink-100">
                <td className="px-4 py-2"><span className="font-mono text-xs">{r.code}</span> {r.name}</td>
                <td className="px-4 py-2 text-ink-600">{r.branch}</td>
                <td className="numeric px-4 py-2">{r.damagedQty || '—'}</td>
                <td className="numeric px-4 py-2">{r.damagedValue ? formatINR(r.damagedValue) : '—'}</td>
                <td className="numeric px-4 py-2">{r.consignmentQty || '—'}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </SolidPanel>
    </div>
  );
}
