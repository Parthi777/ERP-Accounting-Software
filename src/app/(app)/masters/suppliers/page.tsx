import type { Metadata } from 'next';
import Link from 'next/link';
import { BookOpen, Plus } from 'lucide-react';

import { getSuppliers, type SupplierRow } from '@/server/services/masters/masters-service';
import { requirePermission, hasPermission } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { RowActions } from '@/components/masters/row-actions';
import { formatMobile } from '@/lib/format';

export const metadata: Metadata = { title: 'Suppliers' };
export const dynamic = 'force-dynamic';

const STATUS_TONE: Record<string, 'positive' | 'neutral' | 'danger'> = {
  ACTIVE: 'positive',
  INACTIVE: 'neutral',
  BLOCKED: 'danger',
};

export default async function Page() {
  const context = await requirePermission('masters.suppliers.view');
  const rows = await getSuppliers();
  const canManage = hasPermission(context, 'masters.suppliers.manage');
  const canSeeLedger = hasPermission(context, 'accounting.ledgers.view');

  const columns: Column<SupplierRow>[] = [
    {
      key: 'code',
      header: 'Code',
      render: (r) => <span className="font-mono text-xs text-ink-700">{r.supplier_code}</span>,
    },
    {
      key: 'name',
      header: 'Supplier',
      render: (r) => (
        <span>
          <span className="block font-medium text-ink-900">{r.name}</span>
          {r.contact_person && <span className="block text-[11px] text-ink-400">{r.contact_person}</span>}
        </span>
      ),
    },
    { key: 'type', header: 'Type', render: (r) => r.supplier_type },
    { key: 'mobile', header: 'Mobile', render: (r) => formatMobile(r.mobile) },
    {
      key: 'gstin',
      header: 'GSTIN',
      render: (r) => (r.gstin ? <span className="font-mono text-xs">{r.gstin}</span> : '—'),
    },
    {
      key: 'credit',
      header: 'Credit',
      numeric: true,
      render: (r) => (r.credit_days > 0 ? `${r.credit_days} days` : <span className="text-ink-300">—</span>),
    },
    {
      key: 'status',
      header: 'Status',
      render: (r) => <Badge variant={STATUS_TONE[r.status] ?? 'neutral'}>{r.status}</Badge>,
    },
    {
      key: 'actions',
      header: '',
      headerClassName: 'text-right',
      render: (r) => (
        <div className="flex items-center justify-end gap-1">
          {canSeeLedger && (
            <Button size="sm" variant="ghost" asChild>
              <Link href={`/accounting/supplier-ledger?supplier=${r.id}`} title="Open ledger">
                <BookOpen aria-hidden />
                Ledger
              </Link>
            </Button>
          )}
          <RowActions
            kind="supplier"
            id={r.id}
            label={r.name}
            editHref={`/masters/suppliers/${r.id}/edit`}
            canManage={canManage}
          />
        </div>
      ),
    },
  ];

  return (
    <>
      <PageHeader
        title="Suppliers"
        description="Who the dealer buys from. Payments tagged to a supplier build their ledger, which reconciles to Supplier Payables (spec §41)."
        count={rows.length}
        action={
          canManage ? (
            <Button size="sm" asChild>
              <Link href="/masters/suppliers/new"><Plus aria-hidden />New supplier</Link>
            </Button>
          ) : undefined
        }
      />

      <DataTable
        columns={columns}
        rows={rows}
        getRowKey={(row) => row.id}
        emptyMessage="No suppliers yet."
        caption="Suppliers"
      />
    </>
  );
}
