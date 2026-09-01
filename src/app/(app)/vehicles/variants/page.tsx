import type { Metadata } from 'next';
import Link from 'next/link';
import { Plus } from 'lucide-react';

import { getVehicleVariants } from '@/server/services/masters/masters-service';
import { requireTenantContext } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { RowActions } from '@/components/masters/row-actions';
import type { VehicleVariantWithModel } from '@/server/services/masters/masters-service';

export const metadata: Metadata = { title: 'Variants' };
export const dynamic = 'force-dynamic';

export default async function Page() {
  const context = await requireTenantContext();
  const rows = await getVehicleVariants();
  const canManage = context.permissions.has('vehicles.models.manage');

  const columns: Column<VehicleVariantWithModel>[] = [
    { key: 'code', header: 'Code', render: (r) => <span className="font-mono text-xs text-ink-700">{r.variant_code}</span> },
    { key: 'model', header: 'Model', render: (r) => <span className="text-ink-500">{r.model_label}</span> },
    { key: 'name', header: 'Variant', render: (r) => <span className="font-medium text-ink-900">{r.name}</span> },
    { key: 'cc', header: 'Engine', numeric: true, render: (r) => (r.engine_cc ? `${Number(r.engine_cc)} cc` : '—') },
    { key: 'brake', header: 'Brakes', render: (r) => r.brake_type ?? '—' },
    { key: 'status', header: 'Status', render: (r) => <Badge variant={r.status === 'ACTIVE' ? 'positive' : 'neutral'}>{r.status}</Badge> },
    {
      key: 'actions', header: '', headerClassName: 'text-right',
      render: (r) => (
        <RowActions kind="vehicle_variant" id={r.id} label={r.name} editHref={`/vehicles/variants/${r.id}/edit`} canManage={canManage} />
      ),
    },
  ];

  return (
    <div>
      <PageHeader
        title="Variants"
        description="Variants sit beneath a model. Pricing attaches at this level."
        count={rows.length}
        action={
          canManage ? (
            <Button asChild>
              <Link href="/vehicles/variants/new">
                <Plus aria-hidden />
                New variant
              </Link>
            </Button>
          ) : undefined
        }
      />
      <DataTable
        columns={columns}
        rows={rows}
        getRowKey={(row) => row.id}
        caption="Variants"
        emptyMessage="Nothing here yet. Create the first record to get started."
        maxHeight="42rem"
      />
    </div>
  );
}
