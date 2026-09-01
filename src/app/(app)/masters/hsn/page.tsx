import type { Metadata } from 'next';
import Link from 'next/link';
import { Plus } from 'lucide-react';

import { getHsnCodes } from '@/server/services/masters/masters-service';
import { requireTenantContext } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { RowActions } from '@/components/masters/row-actions';
import type { HsnRow } from '@/server/services/masters/masters-service';

export const metadata: Metadata = { title: 'HSN / SAC Codes' };
export const dynamic = 'force-dynamic';

export default async function Page() {
  const context = await requireTenantContext();
  const rows = await getHsnCodes();
  const canManage = context.permissions.has('masters.hsn.manage');

  const columns: Column<HsnRow>[] = [
    { key: 'code', header: 'Code', render: (r) => <span className="font-mono text-xs text-ink-700">{r.code}</span> },
    { key: 'type', header: 'Type', render: (r) => <Badge variant={r.code_type === 'SAC' ? 'accent' : 'info'}>{r.code_type}</Badge> },
    { key: 'description', header: 'Description', render: (r) => r.description },
    { key: 'status', header: 'Status', render: (r) => <Badge variant={r.status === 'ACTIVE' ? 'positive' : 'neutral'}>{r.status}</Badge> },
    {
      key: 'actions', header: '', headerClassName: 'text-right',
      render: (r) => (
        <RowActions kind="hsn" id={r.id} label={r.code} editHref={`/masters/hsn/${r.id}/edit`} canManage={canManage} />
      ),
    },
  ];

  return (
    <div>
      <PageHeader
        title="HSN / SAC Codes"
        description="Goods use HSN, services use SAC. Tax codes and items reference these."
        count={rows.length}
        action={
          canManage ? (
            <Button asChild>
              <Link href="/masters/hsn/new">
                <Plus aria-hidden />
                New code
              </Link>
            </Button>
          ) : undefined
        }
      />
      <DataTable
        columns={columns}
        rows={rows}
        getRowKey={(row) => row.id}
        caption="HSN / SAC Codes"
        emptyMessage="Nothing here yet. Create the first record to get started."
        maxHeight="42rem"
      />
    </div>
  );
}
