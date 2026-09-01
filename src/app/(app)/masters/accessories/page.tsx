import type { Metadata } from 'next';
import Link from 'next/link';
import { Plus } from 'lucide-react';

import { getInventoryItems, type InventoryItemRow } from '@/server/services/masters/masters-service';
import { requireTenantContext } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { RowActions } from '@/components/masters/row-actions';
import { formatINR, fromDb } from '@/lib/money';

export const metadata: Metadata = { title: 'Accessories' };
export const dynamic = 'force-dynamic';

export default async function Page() {
  const context = await requireTenantContext();
  const rows = await getInventoryItems('ACCESSORY');
  const canManage = context.permissions.has('inventory.items.manage');
  // Cost is restricted (spec §52); the column is dropped entirely for roles
  // without the permission rather than rendered blank.
  const canSeeCost = context.permissions.has('inventory.view_cost');

  const columns: Column<InventoryItemRow>[] = [
    { key: 'code', header: 'Item code', render: (r) => <span className="font-mono text-xs text-ink-700">{r.item_code}</span> },
    { key: 'name', header: 'Name', render: (r) => (
      <span>
        <span className="font-medium text-ink-900">{r.name}</span>
        {r.is_fitment && <Badge variant="accent" className="ml-2">Fitment</Badge>}
      </span>
    ) },
    { key: 'brand', header: 'Brand', render: (r) => r.brand ?? '—' },
    { key: 'uom', header: 'UOM', render: (r) => r.uom },
    ...(canSeeCost
      ? [{ key: 'cost', header: 'Std cost', numeric: true, render: (r: InventoryItemRow) => formatINR(fromDb(r.standard_cost)) }]
      : []),
    { key: 'price', header: 'Selling price', numeric: true, render: (r) => formatINR(fromDb(r.selling_price)) },
    { key: 'status', header: 'Status', render: (r) => <Badge variant={r.status === 'ACTIVE' ? 'positive' : 'neutral'}>{r.status}</Badge> },
    {
      key: 'actions', header: '', headerClassName: 'text-right',
      render: (r) => (
        <RowActions kind="inventory_item" id={r.id} label={r.name} editHref={`/masters/accessories/${r.id}/edit`} canManage={canManage} />
      ),
    },
  ];

  return (
    <div>
      <PageHeader
        title="Accessories"
        description="LOCAL and COMPANY stock is tracked separately per branch — see the stock screens."
        count={rows.length}
        action={
          canManage ? (
            <Button asChild>
              <Link href="/masters/accessories/new"><Plus aria-hidden />New item</Link>
            </Button>
          ) : undefined
        }
      />
      <DataTable
        columns={columns}
        rows={rows}
        getRowKey={(row) => row.id}
        caption="Accessories"
        emptyMessage="No items yet. Create the first one to get started."
        maxHeight="42rem"
      />
    </div>
  );
}
