import type { Metadata } from 'next';

import { getStockLots, type StockLotRow } from '@/server/services/inventory/inventory-service';
import { requirePermission, hasPermission } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { StockTransferForm } from '@/components/inventory/stock-transfer-form';
import { Badge } from '@/components/ui/badge';
import { ExportButtons } from '@/components/export/export-buttons';
import { formatINR } from '@/lib/money';

export const metadata: Metadata = { title: 'Stock transfers' };
export const dynamic = 'force-dynamic';

export default async function Page() {
  const context = await requirePermission('inventory.stock.transfer');

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
        title="Stock transfers"
        description="Accessory and spare movements between branches, with the local/company split preserved (spec §35, §60.16)."
        count={lots.length}
        action={<ExportButtons report="stock-lots" />}
      />

      <div className="mb-4">
        <StockTransferForm lots={lots} branches={context.accessibleBranches} />
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
