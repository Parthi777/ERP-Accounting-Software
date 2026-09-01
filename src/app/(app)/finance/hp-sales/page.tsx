import type { Metadata } from 'next';
import Link from 'next/link';

import {
  getFinanceApplications,
  getFinancePickers,
  summarise,
  type FinanceApplicationRow,
} from '@/server/services/finance/finance-service';
import { requirePermission, hasPermission } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { ApplicationActions } from '@/components/finance/application-actions';
import { Panel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { formatINR, toRupees } from '@/lib/money';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'HP sales' };
export const dynamic = 'force-dynamic';

const APPROVAL_TONE: Record<string, 'positive' | 'info' | 'neutral' | 'warning' | 'danger'> = {
  PENDING: 'warning',
  APPROVED: 'positive',
  REJECTED: 'danger',
  CANCELLED: 'neutral',
};

const DISBURSEMENT_TONE: Record<string, 'positive' | 'info' | 'neutral' | 'warning' | 'danger'> = {
  PENDING: 'neutral',
  PARTIAL: 'warning',
  DISBURSED: 'positive',
  CANCELLED: 'neutral',
};

const STATUSES = ['ALL', 'PENDING', 'APPROVED', 'REJECTED', 'CANCELLED'];

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<{ status?: string; q?: string }>;
}) {
  const context = await requirePermission('finance.applications.view');
  const params = await searchParams;
  const status = params.status ?? 'ALL';

  const canManage = hasPermission(context, 'finance.applications.manage');
  const showCommission = hasPermission(context, 'finance.commission.view');

  const [rows, pickers] = await Promise.all([
    getFinanceApplications({ status, branchId: null, q: params.q }),
    canManage ? getFinancePickers() : Promise.resolve({ companies: [], bankAccounts: [] }),
  ]);

  const totals = summarise(rows);
  const penetration =
    totals.applications > 0 ? Math.round((totals.approved / totals.applications) * 100) : 0;

  const columns: Column<FinanceApplicationRow>[] = [
    {
      key: 'number',
      header: 'Application',
      render: (row) => (
        <span>
          <span className="block font-mono text-xs text-ink-700">{row.applicationNumber}</span>
          <span className="block text-[11px] text-ink-400">{formatDate(row.applicationDate)}</span>
        </span>
      ),
    },
    {
      key: 'customer',
      header: 'Customer',
      render: (row) => (
        <Link href={`/customers/${row.customerId}`} className="font-medium text-brand-600 hover:underline">
          {row.customerName}
        </Link>
      ),
    },
    { key: 'company', header: 'Financier', render: (row) => row.companyName },
    {
      key: 'chassis',
      header: 'Vehicle',
      render: (row) =>
        row.chassisNo ? (
          <span className="font-mono text-[11px] text-ink-500">{row.chassisNo}</span>
        ) : (
          <span className="text-ink-300">—</span>
        ),
    },
    { key: 'loan', header: 'Loan', numeric: true, render: (row) => formatINR(row.loanAmount) },
    {
      key: 'approved',
      header: 'Approved',
      numeric: true,
      render: (row) =>
        row.approvedAmount === null ? <span className="text-ink-300">—</span> : formatINR(row.approvedAmount),
    },
    {
      key: 'disbursed',
      header: 'Disbursed',
      numeric: true,
      render: (row) => formatINR(row.disbursedAmount),
    },
    {
      key: 'pending',
      header: 'Pending',
      numeric: true,
      render: (row) =>
        row.pendingAmount > 0 ? (
          <span className="font-medium text-warning-700">{formatINR(row.pendingAmount)}</span>
        ) : (
          <span className="text-positive-700">Settled</span>
        ),
    },
    ...(showCommission
      ? ([
          {
            key: 'commission',
            header: 'Commission',
            numeric: true,
            render: (row: FinanceApplicationRow) =>
              row.commissionAmount === null ? '—' : formatINR(row.commissionAmount),
          },
        ] as Column<FinanceApplicationRow>[])
      : []),
    {
      key: 'status',
      header: 'Status',
      render: (row) => (
        <span className="flex flex-col gap-1">
          <Badge variant={APPROVAL_TONE[row.approvalStatus] ?? 'neutral'}>{row.approvalStatus}</Badge>
          {row.approvalStatus === 'APPROVED' && (
            <Badge variant={DISBURSEMENT_TONE[row.disbursementStatus] ?? 'neutral'}>
              {row.disbursementStatus}
            </Badge>
          )}
        </span>
      ),
    },
    {
      key: 'actions',
      header: '',
      render: (row) => (
        <ApplicationActions
          applicationId={row.id}
          applicationNumber={row.applicationNumber}
          approvalStatus={row.approvalStatus}
          disbursementStatus={row.disbursementStatus}
          pendingAmount={toRupees(row.pendingAmount)}
          bankAccounts={pickers.bankAccounts}
          canManage={canManage}
        />
      ),
    },
  ];

  return (
    <>
      <PageHeader
        title="HP sales"
        description="Hire-purchase applications from request to disbursement (spec §27)."
        count={rows.length}
      />

      <div className="mb-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Applications</p>
          <p className="mt-0.5 text-lg font-semibold text-ink-800">{totals.applications}</p>
          <p className="mt-0.5 text-[11px] text-ink-400">{totals.pending} awaiting a decision</p>
        </Panel>
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Approved</p>
          <p className="mt-0.5 text-lg font-semibold text-positive-700">{penetration}%</p>
          <p className="mt-0.5 text-[11px] text-ink-400">
            {totals.approved} of {totals.applications}
          </p>
        </Panel>
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Disbursed</p>
          <p className="mt-0.5 text-lg font-semibold text-ink-800">{formatINR(totals.disbursedAmount)}</p>
        </Panel>
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Pending disbursement</p>
          <p className="mt-0.5 text-lg font-semibold text-warning-700">{formatINR(totals.pendingAmount)}</p>
          <p className="mt-0.5 text-[11px] text-ink-400">Owed by the finance companies</p>
        </Panel>
      </div>

      <Panel className="mb-4 p-4">
        <form method="get" className="flex flex-wrap items-end gap-3">
          <div>
            <label htmlFor="status" className="mb-1.5 block text-xs font-medium text-ink-600">Status</label>
            <select
              id="status" name="status" defaultValue={status}
              className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
            >
              {STATUSES.map((s) => <option key={s} value={s}>{s}</option>)}
            </select>
          </div>
          <div className="min-w-48 flex-1">
            <label htmlFor="q" className="mb-1.5 block text-xs font-medium text-ink-600">Search</label>
            <input
              id="q" name="q" defaultValue={params.q ?? ''}
              placeholder="Application, customer, financier or chassis"
              className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
            />
          </div>
          <Button type="submit" variant="secondary" size="sm">Filter</Button>
        </form>
      </Panel>

      {pickers.companies.length === 0 && canManage && (
        <Panel className="mb-4 border-warning-200 bg-warning-50 p-4 text-sm text-warning-800">
          No finance companies are set up yet. Add them under{' '}
          <Link href="/finance/companies" className="underline">Finance Companies</Link> — spec §25
          requires a separate ledger per company, so applications must name one.
        </Panel>
      )}

      <DataTable
        columns={columns}
        rows={rows}
        getRowKey={(row) => row.id}
        emptyMessage="No finance applications match this filter."
        caption="HP sales"
      />
    </>
  );
}
