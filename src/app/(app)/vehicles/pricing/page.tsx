import type { Metadata } from 'next';
import Link from 'next/link';
import { Plus } from 'lucide-react';

import { getPriceVersions, type PriceVersionRow } from '@/server/services/vehicles/pricing-service';
import { getVehicleModels } from '@/server/services/masters/masters-service';
import { requireTenantContext } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Panel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { formatINR } from '@/lib/money';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'Price History' };
export const dynamic = 'force-dynamic';

const STATUS_TONE: Record<string, 'positive' | 'neutral' | 'warning' | 'info'> = {
  ACTIVE: 'positive',
  SUPERSEDED: 'neutral',
  DRAFT: 'info',
  SUBMITTED: 'info',
  APPROVED: 'info',
  REJECTED: 'warning',
};

export default async function PricingPage({
  searchParams,
}: {
  searchParams: Promise<{ model?: string }>;
}) {
  const context = await requireTenantContext();
  const params = await searchParams;
  const modelId = params.model || null;

  const [rows, models] = await Promise.all([getPriceVersions(modelId), getVehicleModels()]);
  const canManage = context.permissions.has('vehicles.pricing.manage');
  const canSeeCost = context.permissions.has('vehicles.view_cost');

  const columns: Column<PriceVersionRow>[] = [
    {
      key: 'model',
      header: 'Model',
      render: (row) => (
        <span>
          <span className="font-medium text-ink-900">{row.modelLabel}</span>
          {row.variantName && <span className="ml-1 text-ink-500">{row.variantName}</span>}
          {row.branchName && <Badge variant="info" className="ml-2">{row.branchName}</Badge>}
        </span>
      ),
    },
    { key: 'version', header: 'Ver', numeric: true, render: (row) => `v${row.versionNumber}` },
    { key: 'ex', header: 'Ex-showroom', numeric: true, render: (row) => formatINR(row.exShowroom) },
    { key: 'ins', header: 'Insurance', numeric: true, render: (row) => formatINR(row.insurance) },
    { key: 'reg', header: 'LTRT', numeric: true, render: (row) => formatINR(row.registration) },
    { key: 'fwd', header: 'Forwarding', numeric: true, render: (row) => formatINR(row.forwarding) },
    {
      key: 'total',
      header: 'On-road',
      numeric: true,
      render: (row) => <strong className="text-ink-900">{formatINR(row.totalOnRoad)}</strong>,
    },
    ...(canSeeCost
      ? [{
          key: 'cost',
          header: 'Purchase cost',
          numeric: true,
          render: (row: PriceVersionRow) => (row.purchaseCost === null ? '—' : formatINR(row.purchaseCost)),
        }]
      : []),
    { key: 'from', header: 'Effective from', render: (row) => formatDate(row.effectiveFrom) },
    {
      key: 'to',
      header: 'Until',
      render: (row) => (row.effectiveTo ? formatDate(row.effectiveTo) : <span className="text-ink-400">Current</span>),
    },
    {
      key: 'status',
      header: 'Status',
      render: (row) => <Badge variant={STATUS_TONE[row.status] ?? 'neutral'}>{row.status}</Badge>,
    },
  ];

  return (
    <div>
      <PageHeader
        title="Price History"
        description="A price is never edited. Each change is a new version, and past invoices keep the version they used."
        count={rows.length}
        action={
          canManage ? (
            <Button asChild>
              <Link href="/vehicles/pricing/new"><Plus aria-hidden />New price version</Link>
            </Button>
          ) : undefined
        }
      />

      <Panel className="mb-4 p-3">
        <form method="GET" className="flex flex-wrap items-center gap-2">
          <select name="model" defaultValue={modelId ?? ''} aria-label="Model"
            className="h-9 rounded-lg border border-ink-200 bg-white px-2 text-sm text-ink-700 shadow-sm">
            <option value="">All models</option>
            {models.map((m) => <option key={m.id} value={m.id}>{m.brand} {m.name}</option>)}
          </select>
          <Button type="submit" variant="secondary" size="sm">Filter</Button>
          {modelId && (
            <Button variant="ghost" size="sm" asChild><Link href="/vehicles/pricing">Clear</Link></Button>
          )}
        </form>
      </Panel>

      <DataTable
        columns={columns}
        rows={rows}
        getRowKey={(row) => row.id}
        caption="Price versions"
        emptyMessage="No prices configured yet. Create one to enable vehicle sales."
        maxHeight="40rem"
      />

      <p className="mt-3 text-xs text-ink-500">
        A superseded version cannot be edited — the database refuses it. That is what keeps the answer to
        &ldquo;what was the price on that date?&rdquo; trustworthy.
      </p>
    </div>
  );
}
