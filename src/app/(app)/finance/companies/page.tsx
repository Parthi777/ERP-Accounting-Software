import type { Metadata } from 'next';
import Link from 'next/link';
import { Plus } from 'lucide-react';

import { getFinanceCompanies, type FinanceCompanyRow } from '@/server/services/masters/masters-service';
import { requireTenantContext } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { RowActions } from '@/components/masters/row-actions';
import { formatMobile } from '@/lib/format';

export const metadata: Metadata = { title: 'Finance Companies' };
export const dynamic = 'force-dynamic';

export default async function Page() {
  const context = await requireTenantContext();
  const rows = await getFinanceCompanies();
  const canManage = context.permissions.has('finance.companies.manage');
  const canSeeCommission = context.permissions.has('finance.commission.view');

  const columns: Column<FinanceCompanyRow>[] = [
    { key: 'code', header: 'Code', render: (r) => <span className="font-mono text-xs text-ink-700">{r.code}</span> },
    { key: 'name', header: 'Company', render: (r) => <span className="font-medium text-ink-900">{r.name}</span> },
    { key: 'contact', header: 'Contact', render: (r) => r.contact_person ?? '—' },
    { key: 'mobile', header: 'Mobile', render: (r) => formatMobile(r.mobile) },
    { key: 'gstin', header: 'GSTIN', render: (r) => (r.gstin ? <span className="font-mono text-xs">{r.gstin}</span> : '—') },
    ...(canSeeCommission
      ? [{ key: 'commission', header: 'Commission', numeric: true, render: (r: FinanceCompanyRow) => `${Number(r.commission_percent)}%` }]
      : []),
    { key: 'status', header: 'Status', render: (r) => <Badge variant={r.status === 'ACTIVE' ? 'positive' : 'neutral'}>{r.status}</Badge> },
    {
      key: 'actions', header: '', headerClassName: 'text-right',
      render: (r) => (
        <RowActions kind="finance_company" id={r.id} label={r.name} editHref={`/finance/companies/${r.id}/edit`} canManage={canManage} />
      ),
    },
  ];

  return (
    <div>
      <PageHeader
        title="Finance Companies"
        description="Each company keeps its own ledger. Balances are never combined into one generic figure."
        count={rows.length}
        action={
          canManage ? (
            <Button asChild>
              <Link href="/finance/companies/new"><Plus aria-hidden />New company</Link>
            </Button>
          ) : undefined
        }
      />
      <DataTable
        columns={columns}
        rows={rows}
        getRowKey={(row) => row.id}
        caption="Finance companies"
        emptyMessage="No finance companies yet."
      />
    </div>
  );
}
