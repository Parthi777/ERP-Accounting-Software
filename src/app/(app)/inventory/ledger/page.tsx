import type { Metadata } from 'next';

import {
  getStockLedger,
  getLedgerItemOptions,
  MOVEMENT_TYPES,
  type LedgerEntry,
} from '@/server/services/inventory/inventory-service';
import { requirePermission, hasPermission } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Panel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { formatINR } from '@/lib/money';
import { formatDateTime } from '@/lib/format';
import { monthRange } from '@/lib/period';

export const metadata: Metadata = { title: 'Stock ledger' };
export const dynamic = 'force-dynamic';

/**
 * Receipts read as positive, issues as negative — spec §34. The tone follows the
 * direction of the movement rather than whether it is "good": a sale is a
 * perfectly healthy issue.
 */
const TYPE_TONE: Record<string, 'positive' | 'info' | 'neutral' | 'warning' | 'danger'> = {
  OPENING: 'neutral',
  PURCHASE: 'positive',
  TRANSFER_IN: 'positive',
  RETURN: 'positive',
  SALE: 'info',
  CONSUMPTION: 'info',
  TRANSFER_OUT: 'info',
  ADJUSTMENT: 'warning',
  REVERSAL: 'danger',
};

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<{
    from?: string;
    to?: string;
    item?: string;
    type?: string;
    source?: string;
  }>;
}) {
  const context = await requirePermission('inventory.ledger.view');
  const params = await searchParams;
  const { from, to } = monthRange(params.from, params.to);
  const type = params.type ?? 'ALL';
  const source = params.source ?? 'ALL';

  const [{ entries, totals }, items] = await Promise.all([
    getStockLedger({
      branchId: null,
      itemId: params.item || null,
      type,
      source,
      from,
      to,
    }),
    getLedgerItemOptions(),
  ]);

  const showCost = hasPermission(context, 'inventory.view_cost');

  const columns: Column<LedgerEntry>[] = [
    {
      key: 'at',
      header: 'When',
      render: (row) => <span className="text-xs text-ink-600">{formatDateTime(row.at)}</span>,
    },
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
    { key: 'branch', header: 'Branch', render: (row) => row.branchName },
    {
      key: 'source',
      header: 'Source',
      render: (row) => (
        <Badge variant={row.source === 'LOCAL' ? 'info' : 'neutral'}>{row.source}</Badge>
      ),
    },
    {
      key: 'type',
      header: 'Movement',
      render: (row) => (
        <Badge variant={TYPE_TONE[row.type] ?? 'neutral'}>{row.type.replace('_', ' ')}</Badge>
      ),
    },
    {
      key: 'reference',
      header: 'Reference',
      render: (row) =>
        row.referenceNumber ? (
          <span className="font-mono text-[11px] text-ink-600">{row.referenceNumber}</span>
        ) : row.referenceType ? (
          <span className="text-[11px] text-ink-400">{row.referenceType.replace('_', ' ')}</span>
        ) : (
          <span className="text-ink-300">—</span>
        ),
    },
    {
      key: 'detail',
      header: 'Particulars',
      render: (row) => (
        <span className="block max-w-xs">
          {row.narration && <span className="block text-ink-600">{row.narration}</span>}
          {/* The reason is the point of an adjustment, so it is never truncated away. */}
          {row.reason && <span className="block text-[11px] text-warning-700">{row.reason}</span>}
          {!row.narration && !row.reason && <span className="text-ink-300">—</span>}
        </span>
      ),
    },
    {
      key: 'quantity',
      header: 'Quantity',
      numeric: true,
      render: (row) => (
        <span className={row.quantity > 0 ? 'text-positive-700' : 'text-danger-700'}>
          {row.quantity > 0 ? '+' : ''}
          {row.quantity}
        </span>
      ),
    },
    ...(showCost
      ? ([
          {
            key: 'value',
            header: 'Value',
            numeric: true,
            render: (row: LedgerEntry) => formatINR(row.value),
          },
        ] as Column<LedgerEntry>[])
      : []),
    {
      key: 'balance',
      header: 'Balance after',
      numeric: true,
      render: (row) => <span className="font-medium text-ink-800">{row.balanceAfter}</span>,
    },
  ];

  return (
    <>
      <PageHeader
        title="Stock ledger"
        description="Every accessory and spare movement, in the order it happened, with the balance it left behind (spec §34)."
        count={entries.length}
      />

      <Panel className="mb-4 p-4">
        <form method="get" className="flex flex-wrap items-end gap-3">
          <div>
            <label htmlFor="from" className="mb-1.5 block text-xs font-medium text-ink-600">From</label>
            <input
              id="from" name="from" type="date" defaultValue={from}
              className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
            />
          </div>
          <div>
            <label htmlFor="to" className="mb-1.5 block text-xs font-medium text-ink-600">To</label>
            <input
              id="to" name="to" type="date" defaultValue={to}
              className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
            />
          </div>
          <div className="min-w-56">
            <label htmlFor="item" className="mb-1.5 block text-xs font-medium text-ink-600">Item</label>
            <select
              id="item" name="item" defaultValue={params.item ?? ''}
              className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
            >
              <option value="">All items</option>
              {items.map((i) => (
                <option key={i.id} value={i.id}>{i.label}</option>
              ))}
            </select>
          </div>
          <div>
            <label htmlFor="type" className="mb-1.5 block text-xs font-medium text-ink-600">Movement</label>
            <select
              id="type" name="type" defaultValue={type}
              className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
            >
              <option value="ALL">All movements</option>
              {MOVEMENT_TYPES.map((t) => (
                <option key={t} value={t}>{t.replace('_', ' ')}</option>
              ))}
            </select>
          </div>
          <div>
            <label htmlFor="source" className="mb-1.5 block text-xs font-medium text-ink-600">Source</label>
            <select
              id="source" name="source" defaultValue={source}
              className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
            >
              <option value="ALL">Local and company</option>
              <option value="LOCAL">Local</option>
              <option value="COMPANY">Company</option>
            </select>
          </div>
          <Button type="submit" variant="secondary" size="sm">Filter</Button>
        </form>
      </Panel>

      <div className="mb-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Received</p>
          <p className="mt-0.5 text-lg font-semibold text-positive-700">+{totals.received}</p>
        </Panel>
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Issued</p>
          <p className="mt-0.5 text-lg font-semibold text-danger-700">-{totals.issued}</p>
        </Panel>
        {showCost && (
          <>
            <Panel className="p-4">
              <p className="text-xs text-ink-500">Value in</p>
              <p className="mt-0.5 text-lg font-semibold text-ink-800">{formatINR(totals.receivedValue)}</p>
            </Panel>
            <Panel className="p-4">
              <p className="text-xs text-ink-500">Value out</p>
              <p className="mt-0.5 text-lg font-semibold text-ink-800">{formatINR(totals.issuedValue)}</p>
            </Panel>
          </>
        )}
      </div>

      <DataTable
        columns={columns}
        rows={entries}
        getRowKey={(row) => String(row.id)}
        emptyMessage="No stock movements in this period."
        caption="Stock ledger"
        maxHeight="40rem"
      />

      {entries.length === 500 && (
        <p className="mt-2 text-xs text-ink-500">
          Showing the 500 most recent movements in this range. Narrow the dates or pick an item to
          see the rest.
        </p>
      )}
    </>
  );
}
