import type { Metadata } from 'next';

import {
  getInventoryMovement,
  getInventoryStockReport,
  getVehicleStockReport,
  type InventoryMovementRow,
  type InventoryStockRow,
  type VehicleStockRow,
} from '@/server/services/reports/reports-service';
import { requirePermission, hasPermission } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Panel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { ExportButtons } from '@/components/export/export-buttons';
import { add, formatINR, paise } from '@/lib/money';
import { monthRange } from '@/lib/period';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'Inventory report' };
export const dynamic = 'force-dynamic';

const AGE_TONE: Record<string, 'positive' | 'info' | 'warning' | 'danger'> = {
  '0-30': 'positive',
  '31-60': 'info',
  '61-90': 'warning',
  '90+': 'danger',
};

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<{ from?: string; to?: string; view?: string }>;
}) {
  const context = await requirePermission('reports.inventory.view');
  const params = await searchParams;
  const range = monthRange(params.from, params.to);
  const view = params.view ?? 'VEHICLES';

  const showCost = hasPermission(context, 'vehicles.view_cost') || hasPermission(context, 'inventory.view_cost');

  const [vehicles, items, movement] = await Promise.all([
    view === 'VEHICLES' ? getVehicleStockReport({ status: 'IN_STOCK' }) : Promise.resolve([]),
    view === 'PARTS' ? getInventoryStockReport({}) : Promise.resolve([]),
    view === 'MOVEMENT' ? getInventoryMovement({ from: range.from, to: range.to }) : Promise.resolve([]),
  ]);

  const vehicleColumns: Column<VehicleStockRow>[] = [
    {
      key: 'chassis',
      header: 'Chassis',
      render: (row) => <span className="font-mono text-xs">{row.chassisNo}</span>,
    },
    {
      key: 'model',
      header: 'Model',
      render: (row) => (
        <span>
          <span className="block">{row.brand} {row.modelName}</span>
          {row.variantName && <span className="block text-[11px] text-ink-400">{row.variantName}</span>}
        </span>
      ),
    },
    { key: 'branch', header: 'Branch', render: (row) => row.branchName },
    { key: 'stockDate', header: 'In stock since', render: (row) => formatDate(row.stockDate) },
    { key: 'age', header: 'Age', numeric: true, render: (row) => `${row.ageDays} days` },
    {
      key: 'bucket',
      header: 'Ageing',
      render: (row) => <Badge variant={AGE_TONE[row.ageBucket] ?? 'neutral'}>{row.ageBucket}</Badge>,
    },
    ...(showCost
      ? [{
          key: 'cost',
          header: 'Cost',
          numeric: true,
          render: (row: VehicleStockRow) => (row.purchaseCost != null ? formatINR(row.purchaseCost) : '—'),
        }]
      : []),
  ];

  const itemColumns: Column<InventoryStockRow>[] = [
    {
      key: 'item',
      header: 'Item',
      render: (row) => (
        <span>
          <span className="block">{row.itemName}</span>
          <span className="block font-mono text-[11px] text-ink-400">{row.itemCode}</span>
        </span>
      ),
    },
    { key: 'type', header: 'Type', render: (row) => row.itemType },
    { key: 'branch', header: 'Branch', render: (row) => row.branchName },
    { key: 'local', header: 'Local', numeric: true, render: (row) => row.localQty },
    { key: 'company', header: 'Company', numeric: true, render: (row) => row.companyQty },
    {
      key: 'total',
      header: 'Total',
      numeric: true,
      render: (row) => <span className="font-medium">{row.totalQty}</span>,
    },
    { key: 'value', header: 'Stock value', numeric: true, render: (row) => formatINR(row.totalValue) },
  ];

  const movementColumns: Column<InventoryMovementRow>[] = [
    {
      key: 'item',
      header: 'Item',
      render: (row) => (
        <span>
          <span className="block">{row.itemName}</span>
          <span className="block font-mono text-[11px] text-ink-400">{row.itemCode}</span>
        </span>
      ),
    },
    { key: 'type', header: 'Type', render: (row) => row.itemType },
    {
      key: 'received',
      header: 'Received',
      numeric: true,
      render: (row) => (row.receivedQty > 0 ? <span className="text-positive-700">{row.receivedQty}</span> : '—'),
    },
    {
      key: 'issued',
      header: 'Issued',
      numeric: true,
      render: (row) => (row.issuedQty > 0 ? <span className="text-danger-700">{row.issuedQty}</span> : '—'),
    },
    { key: 'closingQty', header: 'Closing qty', numeric: true, render: (row) => row.closingQty },
    {
      key: 'closingValue',
      header: 'Closing value',
      numeric: true,
      render: (row) => <span className="font-medium">{formatINR(row.closingValue)}</span>,
    },
  ];

  const stockValue = items.reduce((sum, r) => add(sum, r.totalValue), paise(0));

  return (
    <>
      <PageHeader
        title="Inventory report"
        description="Vehicle stock, parts stock and movement. Local and company stock stay separate (spec §31, §60.16)."
        count={view === 'VEHICLES' ? vehicles.length : view === 'PARTS' ? items.length : movement.length}
        action={
          <ExportButtons
            report={
              view === 'VEHICLES'
                ? 'vehicle-stock'
                : view === 'PARTS'
                  ? 'inventory-stock-summary'
                  : 'inventory-movement'
            }
          />
        }
      />

      <Panel className="mb-4 p-4">
        <form method="get" className="flex flex-wrap items-end gap-3">
          <div>
            <label htmlFor="view" className="mb-1.5 block text-xs font-medium text-ink-600">Report</label>
            <select id="view" name="view" defaultValue={view}
              className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm">
              <option value="VEHICLES">Vehicle stock and ageing</option>
              <option value="PARTS">Accessory and spare stock</option>
              <option value="MOVEMENT">Stock movement</option>
            </select>
          </div>
          {view === 'MOVEMENT' && (
            <>
              <div>
                <label htmlFor="from" className="mb-1.5 block text-xs font-medium text-ink-600">From</label>
                <input id="from" name="from" type="date" defaultValue={range.from}
                  className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm" />
              </div>
              <div>
                <label htmlFor="to" className="mb-1.5 block text-xs font-medium text-ink-600">To</label>
                <input id="to" name="to" type="date" defaultValue={range.to}
                  className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm" />
              </div>
            </>
          )}
          <Button type="submit" variant="secondary" size="sm">Show</Button>
        </form>
      </Panel>

      {view === 'VEHICLES' && (
        <>
          <div className="mb-4 grid gap-3 sm:grid-cols-4">
            {['0-30', '31-60', '61-90', '90+'].map((bucket) => {
              const count = vehicles.filter((v) => v.ageBucket === bucket).length;
              return (
                <Panel key={bucket} className="p-4">
                  <p className="text-xs text-ink-500">{bucket} days</p>
                  <p className={`numeric mt-1 text-xl font-semibold ${
                    bucket === '90+' && count > 0 ? 'text-danger-700' : 'text-ink-900'
                  }`}>
                    {count}
                  </p>
                </Panel>
              );
            })}
          </div>
          <DataTable columns={vehicleColumns} rows={vehicles} getRowKey={(row) => row.vehicleId}
            emptyMessage="No vehicles in stock." caption="Vehicle stock and ageing" />
        </>
      )}

      {view === 'PARTS' && (
        <>
          <Panel className="mb-4 p-4">
            <p className="text-xs text-ink-500">Total stock value</p>
            <p className="numeric mt-1 text-xl font-semibold text-ink-900">{formatINR(stockValue)}</p>
          </Panel>
          <DataTable columns={itemColumns} rows={items} getRowKey={(row) => `${row.itemId}:${row.branchName}`}
            emptyMessage="No accessory or spare stock." caption="Accessory and spare stock" />
        </>
      )}

      {view === 'MOVEMENT' && (
        <DataTable columns={movementColumns} rows={movement} getRowKey={(row) => row.itemId}
          emptyMessage="No stock moved in this period." caption="Stock movement" />
      )}
    </>
  );
}
