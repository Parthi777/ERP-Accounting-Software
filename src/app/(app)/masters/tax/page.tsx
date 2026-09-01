import type { Metadata } from 'next';
import Link from 'next/link';
import { Plus } from 'lucide-react';

import { getTaxCodes } from '@/server/services/masters/masters-service';
import { requireTenantContext } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { RowActions } from '@/components/masters/row-actions';
import type { TaxCodeRow } from '@/server/services/masters/masters-service';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'Tax Codes' };
export const dynamic = 'force-dynamic';

export default async function Page() {
  const context = await requireTenantContext();
  const rows = await getTaxCodes();
  const canManage = context.permissions.has('masters.tax.manage');

  const columns: Column<TaxCodeRow>[] = [
    { key: 'code', header: 'Code', render: (r) => <span className="font-mono text-xs text-ink-700">{r.code}</span> },
    { key: 'name', header: 'Name', render: (r) => <span className="font-medium text-ink-900">{r.name}</span> },
    { key: 'cgst', header: 'CGST', numeric: true, render: (r) => `${Number(r.cgst_rate)}%` },
    { key: 'sgst', header: 'SGST', numeric: true, render: (r) => `${Number(r.sgst_rate)}%` },
    { key: 'igst', header: 'IGST', numeric: true, render: (r) => `${Number(r.igst_rate)}%` },
    { key: 'total', header: 'Total', numeric: true, render: (r) => <strong>{Number(r.total_rate)}%</strong> },
    { key: 'from', header: 'Effective from', render: (r) => formatDate(r.effective_from) },
    { key: 'to', header: 'Until', render: (r) => (r.effective_to ? formatDate(r.effective_to) : <Badge variant="positive">Current</Badge>) },
    { key: 'status', header: 'Status', render: (r) => <Badge variant={r.status === 'ACTIVE' ? 'positive' : 'neutral'}>{r.status}</Badge> },
    {
      key: 'actions', header: '', headerClassName: 'text-right',
      render: (r) => (
        <RowActions kind="tax" id={r.id} label={r.code} editHref={`/masters/tax/${r.id}/edit`} canManage={canManage} />
      ),
    },
  ];

  return (
    <div>
      <PageHeader
        title="Tax Codes"
        description="GST rates are effective-dated. A historical invoice keeps the rate that applied on its date."
        count={rows.length}
        action={
          canManage ? (
            <Button asChild>
              <Link href="/masters/tax/new">
                <Plus aria-hidden />
                New tax code
              </Link>
            </Button>
          ) : undefined
        }
      />
      <DataTable
        columns={columns}
        rows={rows}
        getRowKey={(row) => row.id}
        caption="Tax Codes"
        emptyMessage="Nothing here yet. Create the first record to get started."
        maxHeight="42rem"
      />
    </div>
  );
}
