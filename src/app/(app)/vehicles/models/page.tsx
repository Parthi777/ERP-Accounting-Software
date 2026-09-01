import type { Metadata } from 'next';
import Link from 'next/link';
import { Plus } from 'lucide-react';

import { getVehicleModels } from '@/server/services/masters/masters-service';
import { requireTenantContext } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { RowActions } from '@/components/masters/row-actions';
import type { VehicleModelWithCounts } from '@/server/services/masters/masters-service';

export const metadata: Metadata = { title: 'Vehicle Models' };
export const dynamic = 'force-dynamic';

export default async function Page() {
  const context = await requireTenantContext();
  const rows = await getVehicleModels();
  const canManage = context.permissions.has('vehicles.models.manage');

  const columns: Column<VehicleModelWithCounts>[] = [
    { key: 'code', header: 'Code', render: (r) => <span className="font-mono text-xs text-ink-700">{r.model_code}</span> },
    { key: 'name', header: 'Model', render: (r) => (
      <span><span className="text-ink-500">{r.brand}</span> <span className="font-medium text-ink-900">{r.name}</span></span>
    ) },
    { key: 'category', header: 'Category', render: (r) => <Badge variant="info">{r.category.replace('_', ' ')}</Badge> },
    { key: 'fuel', header: 'Fuel', render: (r) => r.fuel_type },
    { key: 'variants', header: 'Variants', numeric: true, render: (r) => r.variant_count },
    { key: 'status', header: 'Status', render: (r) => <Badge variant={r.status === 'ACTIVE' ? 'positive' : 'neutral'}>{r.status}</Badge> },
    {
      key: 'actions', header: '', headerClassName: 'text-right',
      render: (r) => (
        <RowActions kind="vehicle_model" id={r.id} label={r.name} editHref={`/vehicles/models/${r.id}/edit`} canManage={canManage} />
      ),
    },
  ];

  return (
    <div>
      <PageHeader
        title="Vehicle Models"
        description="The catalogue of what this dealer sells. Physical units live in Vehicle Stock."
        count={rows.length}
        action={
          canManage ? (
            <Button asChild>
              <Link href="/vehicles/models/new">
                <Plus aria-hidden />
                New model
              </Link>
            </Button>
          ) : undefined
        }
      />
      <DataTable
        columns={columns}
        rows={rows}
        getRowKey={(row) => row.id}
        caption="Vehicle Models"
        emptyMessage="Nothing here yet. Create the first record to get started."
        maxHeight="42rem"
      />
    </div>
  );
}
