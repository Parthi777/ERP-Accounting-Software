import type { Metadata } from 'next';

import { getBranches } from '@/server/services/org/org-service';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Badge } from '@/components/ui/badge';
import { formatDate } from '@/lib/format';
import type { BranchRow } from '@/server/services/org/org-service';

export const metadata: Metadata = { title: 'Branches' };
export const dynamic = 'force-dynamic';

const columns: Column<BranchRow>[] = [
  {
    key: 'code',
    header: 'Code',
    render: (row) => <span className="font-mono text-xs text-ink-600">{row.code}</span>,
  },
  {
    key: 'name',
    header: 'Branch',
    render: (row) => (
      <span className="flex items-center gap-2">
        <span className="font-medium text-ink-900">{row.name}</span>
        {row.is_head_office && <Badge variant="info">Head office</Badge>}
      </span>
    ),
  },
  { key: 'city', header: 'City', render: (row) => row.city ?? '—' },
  { key: 'state', header: 'State', render: (row) => row.state ?? '—' },
  {
    key: 'gstin',
    header: 'GSTIN',
    render: (row) => <span className="font-mono text-xs">{row.gstin ?? '—'}</span>,
  },
  {
    key: 'status',
    header: 'Status',
    render: (row) => (
      <Badge variant={row.status === 'ACTIVE' ? 'positive' : 'warning'}>{row.status}</Badge>
    ),
  },
  { key: 'created', header: 'Created', render: (row) => formatDate(row.created_at) },
];

export default async function BranchesPage() {
  const branches = await getBranches();

  return (
    <div>
      <PageHeader
        title="Branches"
        description="Operational units within this dealer. Branch-level data is scoped to these."
        count={branches.length}
      />
      <DataTable
        columns={columns}
        rows={branches}
        getRowKey={(row) => row.id}
        caption="Branches"
        emptyMessage="No branches are visible to your account."
      />
    </div>
  );
}
