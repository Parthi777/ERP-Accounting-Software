import type { Metadata } from 'next';

import { getStockLots, type StockLotRow } from '@/server/services/inventory/inventory-service';
import { requirePermission, hasPermission } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { StockAdjustmentForm } from '@/components/inventory/stock-adjustment-form';
import { Badge } from '@/components/ui/badge';
import { formatINR } from '@/lib/money';

export const metadata: Metadata = { title: 'Stock adjustments' };
export const dynamic = 'force-dynamic';

export default async function Page() {
  const context = await requirePermission('inventory.stock.adjust');

  const lots = await getStockLots({ branchId: null, itemType: 'ALL' });
  const showCost = hasPermission(context, 'inventory.view_cost');

  const columns: Column<StockLotRow>[] = [
    {
      key: 'item',
      header: 'Item',
      render: (row) => (
        <span>
          <span className="block font-medium text-ink-800">{row.itemName}</span>
          <span className="block font-mono text-[11px] text-ink-400">{row.itemCode}</span>
        </span>
      ),
    },
    { key: 'type', header: 'Type', render: (row) => row.itemType },
    { key: 'branch', header: 'Branch', render: (row) => row.branchName },
    {
      key: 'source',
      header: 'Source',
      render: (row) => (
        <Badge variant={row.source === 'LOCAL' ? 'info' : 'neutral'}>{row.source}</Badge>
      ),
    },
    { key: 'quantity', header: 'On hand', numeric: true, render: (row) => row.quantity },
    ...(showCost
      ? ([
          {
            key: 'value',
            header: 'Value',
            numeric: true,
            render: (row: StockLotRow) => formatINR(row.stockValue),
          },
        ] as Column<StockLotRow>[])
      : []),
  ];

  return (
    <>
      <PageHeader
        title="Stock adjustments"
        description="Always an explicit, audited movement with a reason — never a silent quantity change (spec §34, §60.22)."
        count={lots.length}
      />

      <div className="mb-4">
        <StockAdjustmentForm lots={lots} />
      </div>

      <DataTable
        columns={columns}
        rows={lots}
        getRowKey={(row) => `${row.itemId}-${row.branchId}-${row.source}`}
        emptyMessage="No stock at your branches."
        caption="Stock on hand"
      />
    </>
  );
}
