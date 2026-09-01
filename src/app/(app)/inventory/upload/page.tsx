import type { Metadata } from 'next';

import { requirePermission } from '@/server/auth/tenant-context';
import { getLedgerItemOptions } from '@/server/services/inventory/inventory-service';
import { PageHeader } from '@/components/data-table/data-table';
import { OpeningStockUpload } from '@/components/inventory/opening-stock-upload';
import { Panel } from '@/components/ui/panel';

export const metadata: Metadata = { title: 'Stock upload' };
export const dynamic = 'force-dynamic';

export default async function Page() {
  const context = await requirePermission('inventory.stock.upload');
  const items = await getLedgerItemOptions();

  return (
    <>
      <PageHeader
        title="Stock upload"
        description="Opening quantities for accessories and spares, validated before anything is written (spec §14)."
      />

      <div className="mb-4">
        <OpeningStockUpload />
      </div>

      {items.length === 0 && (
        <Panel className="mb-4 border-warning-200 bg-warning-50 p-4 text-sm text-warning-800">
          No active items exist yet. Add accessories and spares under Masters before uploading stock —
          the file is matched to them by item code.
        </Panel>
      )}

      <Panel className="p-5">
        <h2 className="text-sm font-semibold text-ink-900">Codes this dealer accepts</h2>
        <p className="mt-1 text-xs text-ink-500">
          The file is matched on these. Anything else is reported as an error rather than created.
        </p>

        <div className="mt-4 grid gap-4 sm:grid-cols-2">
          <div>
            <p className="mb-1.5 text-xs font-medium text-ink-600">Branches</p>
            <div className="flex flex-wrap gap-1.5">
              {context.accessibleBranches.map((b) => (
                <code key={b.id} className="rounded bg-ink-100 px-1.5 py-0.5 text-[11px] text-ink-700">
                  {b.code}
                </code>
              ))}
            </div>
          </div>

          <div>
            <p className="mb-1.5 text-xs font-medium text-ink-600">Source</p>
            <div className="flex flex-wrap gap-1.5">
              <code className="rounded bg-ink-100 px-1.5 py-0.5 text-[11px] text-ink-700">LOCAL</code>
              <code className="rounded bg-ink-100 px-1.5 py-0.5 text-[11px] text-ink-700">COMPANY</code>
            </div>
            <p className="mt-1 text-[11px] text-ink-400">
              Kept as separate lots with their own cost (spec §28), never merged.
            </p>
          </div>

          {items.length > 0 && (
            <div className="sm:col-span-2">
              <p className="mb-1.5 text-xs font-medium text-ink-600">
                Item codes {items.length > 12 && <span className="text-ink-400">(first 12 of {items.length})</span>}
              </p>
              <div className="flex flex-wrap gap-1.5">
                {items.slice(0, 12).map((i) => (
                  <code key={i.id} className="rounded bg-ink-100 px-1.5 py-0.5 text-[11px] text-ink-700">
                    {i.label.split(' · ')[0]}
                  </code>
                ))}
              </div>
            </div>
          )}
        </div>

        <p className="mt-4 border-t border-ink-100 pt-3 text-xs text-ink-500">
          An opening balance records stock the dealer already holds, so it creates quantity and value
          without a journal — the same as the vehicle stock upload. It is a starting position, not a
          purchase; buy stock through a purchase so the ledger sees the other side.
        </p>
      </Panel>
    </>
  );
}
