import type { Metadata } from 'next';
import Link from 'next/link';
import { Plus } from 'lucide-react';

import {
  getPriceApprovalQueue,
  type PriceApprovalRow,
} from '@/server/services/vehicles/pricing-service';
import { requirePermission, hasPermission } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { PriceApprovalActions } from '@/components/vehicles/price-approval-actions';
import { Panel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { formatINR, subtract, percentageOf } from '@/lib/money';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'Pricing' };
export const dynamic = 'force-dynamic';

const STATUS_TONE: Record<string, 'positive' | 'info' | 'neutral' | 'warning' | 'danger'> = {
  DRAFT: 'neutral',
  SUBMITTED: 'warning',
  APPROVED: 'info',
  ACTIVE: 'positive',
  SUPERSEDED: 'neutral',
  REJECTED: 'danger',
};

const VIEWS = ['SUBMITTED', 'DRAFT', 'APPROVED', 'ACTIVE', 'REJECTED', 'ALL'];

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<{ status?: string }>;
}) {
  const context = await requirePermission('masters.pricing.manage');
  const params = await searchParams;
  const status = params.status && VIEWS.includes(params.status) ? params.status : 'SUBMITTED';

  const rows = await getPriceApprovalQueue(status);

  const canManage = hasPermission(context, 'masters.pricing.manage');
  const canApprove = hasPermission(context, 'vehicles.pricing.approve');
  const showCost = hasPermission(context, 'vehicles.view_cost');

  const columns: Column<PriceApprovalRow>[] = [
    {
      key: 'model',
      header: 'Model',
      render: (row) => (
        <span>
          <span className="font-medium text-ink-900">{row.modelLabel}</span>
          {row.variantName && <span className="ml-1 text-ink-500">{row.variantName}</span>}
          {row.branchName && <Badge variant="info" className="ml-2">{row.branchName}</Badge>}
          <span className="block text-[11px] text-ink-400">
            v{row.versionNumber} · from {formatDate(row.effectiveFrom)}
          </span>
        </span>
      ),
    },
    { key: 'ex', header: 'Ex-showroom', numeric: true, render: (row) => formatINR(row.exShowroom) },
    { key: 'onroad', header: 'On-road', numeric: true, render: (row) => formatINR(row.totalOnRoad) },
    ...(showCost
      ? ([
          {
            key: 'margin',
            header: 'Margin',
            numeric: true,
            render: (row: PriceApprovalRow) => {
              if (row.purchaseCost === null) return <span className="text-ink-300">—</span>;
              // What the dealer keeps on the vehicle itself, before fittings.
              const margin = subtract(row.exShowroom, row.purchaseCost);
              const percent = percentageOf(margin, row.exShowroom);
              return (
                <span className={margin > 0 ? 'text-positive-700' : 'text-danger-700'}>
                  {formatINR(margin)}
                  {percent !== null && (
                    <span className="ml-1 text-[11px] text-ink-400">{percent.toFixed(1)}%</span>
                  )}
                </span>
              );
            },
          },
        ] as Column<PriceApprovalRow>[])
      : []),
    {
      key: 'progress',
      header: 'Progress',
      render: (row) => (
        <span className="block text-[11px] text-ink-500">
          {row.submittedAt ? `Submitted ${formatDate(row.submittedAt)}` : 'Not submitted'}
          {row.approvedAt && <span className="block">Approved {formatDate(row.approvedAt)}</span>}
        </span>
      ),
    },
    {
      key: 'status',
      header: 'Status',
      render: (row) => <Badge variant={STATUS_TONE[row.status] ?? 'neutral'}>{row.status}</Badge>,
    },
    {
      key: 'actions',
      header: '',
      render: (row) => (
        <PriceApprovalActions
          versionId={row.id}
          status={row.status}
          canManage={canManage}
          canApprove={canApprove}
        />
      ),
    },
  ];

  return (
    <>
      <PageHeader
        title="Pricing"
        description="Price versions on their way to going live: draft, submitted, approved, active (spec §15)."
        count={rows.length}
        action={
          <Button size="sm" variant="secondary" asChild>
            <Link href="/vehicles/pricing/new"><Plus aria-hidden />New price version</Link>
          </Button>
        }
      />

      <Panel className="mb-4 p-4">
        <p className="text-sm text-ink-700">
          A price does not go live when it is saved.
        </p>
        <p className="mt-1 text-xs text-ink-500">
          Every future invoice is computed from the active price, so a new version starts as a draft
          and reaches <span className="font-medium">Active</span> only through submission and
          approval. Approval must come from someone other than whoever submitted it — otherwise the
          step is decorative. Past invoices keep the price they were raised under
          (<Link href="/vehicles/pricing" className="text-brand-600 hover:underline">price history</Link>).
        </p>
      </Panel>

      <Panel className="mb-4 p-4">
        <form method="get" className="flex flex-wrap items-end gap-3">
          <div>
            <label htmlFor="status" className="mb-1.5 block text-xs font-medium text-ink-600">Status</label>
            <select
              id="status" name="status" defaultValue={status}
              className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
            >
              {VIEWS.map((v) => <option key={v} value={v}>{v}</option>)}
            </select>
          </div>
          <Button type="submit" variant="secondary" size="sm">Filter</Button>
        </form>
      </Panel>

      <DataTable
        columns={columns}
        rows={rows}
        getRowKey={(row) => row.id}
        emptyMessage={
          status === 'SUBMITTED'
            ? 'Nothing is waiting for approval.'
            : 'No price versions match this filter.'
        }
        caption="Price approval queue"
      />
    </>
  );
}
