import type { Metadata } from 'next';
import Link from 'next/link';
import { Bike, Clock, Search, Upload, Wallet } from 'lucide-react';

import { getVehicles, getStockSummary, type VehicleListRow } from '@/server/services/vehicles/vehicle-service';
import { getVehicleModels } from '@/server/services/masters/masters-service';
import { requireTenantContext } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Panel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { formatINR, formatINRShort } from '@/lib/money';
import { formatDate, formatNumber } from '@/lib/format';

export const metadata: Metadata = { title: 'Vehicle Stock' };
export const dynamic = 'force-dynamic';

const STATUS_TONE: Record<string, 'positive' | 'info' | 'warning' | 'neutral' | 'danger'> = {
  IN_STOCK: 'positive',
  BOOKED: 'info',
  SOLD_PENDING_DELIVERY: 'warning',
  DELIVERED: 'neutral',
  TRANSFERRED: 'neutral',
  CANCELLED: 'danger',
};

/** Ageing colour follows the risk: old stock costs money (spec §41). */
function ageTone(days: number): string {
  if (days <= 30) return 'text-positive-700';
  if (days <= 90) return 'text-ink-600';
  if (days <= 180) return 'text-warning-700';
  return 'text-danger-700';
}

export default async function VehicleStockPage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string; status?: string; branch?: string; model?: string; page?: string }>;
}) {
  const context = await requireTenantContext();
  const params = await searchParams;

  const status = params.status ?? 'IN_STOCK';
  const branchId = params.branch === 'all' ? null : (params.branch ?? null);
  const modelId = params.model || null;
  const page = Math.max(1, Number(params.page ?? '1') || 1);

  const [result, summary, models] = await Promise.all([
    getVehicles({ q: params.q, status, branchId, modelId, page }),
    getStockSummary(branchId),
    getVehicleModels(),
  ]);

  const canSeeCost = context.permissions.has('vehicles.view_cost');
  const canUpload = context.permissions.has('vehicles.stock.upload');

  const columns: Column<VehicleListRow>[] = [
    {
      key: 'chassis',
      header: 'Chassis',
      render: (row) => (
        <Link href={`/vehicles/${row.id}`} className="font-mono text-xs text-brand-600 hover:underline">
          {row.chassis_no}
        </Link>
      ),
    },
    {
      key: 'model',
      header: 'Model',
      render: (row) => (
        <span>
          <span className="font-medium text-ink-900">
            {row.brand} {row.model_name}
          </span>
          {row.variant_name && <span className="ml-1 text-ink-500">{row.variant_name}</span>}
        </span>
      ),
    },
    { key: 'engine', header: 'Engine', render: (row) => <span className="font-mono text-xs">{row.engine_no}</span> },
    { key: 'branch', header: 'Branch', render: (row) => row.branch_name },
    { key: 'stock_date', header: 'In stock since', render: (row) => formatDate(row.stock_date) },
    {
      key: 'age',
      header: 'Age',
      numeric: true,
      render: (row) => <span className={ageTone(row.age_days)}>{row.age_days} d</span>,
    },
    // Purchase cost is stripped server-side for roles without the permission,
    // so the column is omitted rather than rendered empty (spec §52).
    ...(canSeeCost
      ? [
          {
            key: 'cost',
            header: 'Purchase cost',
            numeric: true,
            render: (row: VehicleListRow) => formatINR(row.purchase_cost),
          },
        ]
      : []),
    {
      key: 'status',
      header: 'Status',
      render: (row) => (
        <Badge variant={STATUS_TONE[row.status] ?? 'neutral'}>{row.status.replace(/_/g, ' ')}</Badge>
      ),
    },
  ];

  const pageHref = (next: number) => {
    const q = new URLSearchParams();
    if (params.q) q.set('q', params.q);
    if (status !== 'IN_STOCK') q.set('status', status);
    if (params.branch) q.set('branch', params.branch);
    if (modelId) q.set('model', modelId);
    q.set('page', String(next));
    return `/vehicles?${q.toString()}`;
  };

  return (
    <div>
      <PageHeader
        title="Vehicle Stock"
        description="Chassis-level. Every row is one physical vehicle — there is no quantity here."
        count={result.total}
        action={
          canUpload ? (
            <Button asChild>
              <Link href="/vehicles/upload">
                <Upload aria-hidden />
                Upload stock
              </Link>
            </Button>
          ) : undefined
        }
      />

      <div className="mb-4 grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <Stat icon={Bike} label="In stock" value={formatNumber(summary.inStock)} tone="positive" />
        <Stat icon={Clock} label="Booked" value={formatNumber(summary.booked)} tone="info" />
        <Stat icon={Clock} label="Sold, awaiting delivery" value={formatNumber(summary.soldPending)} tone="warning" />
        {canSeeCost && (
          <Stat icon={Wallet} label="Stock value" value={formatINRShort(summary.stockValue)} tone="accent" />
        )}
      </div>

      {summary.inStock > 0 && (
        <Panel className="mb-4 p-4">
          <p className="mb-2 text-xs font-medium uppercase tracking-wide text-ink-400">Stock ageing</p>
          <div className="flex flex-wrap gap-2">
            {Object.entries(summary.ageing).map(([bucket, count]) => (
              <span
                key={bucket}
                className="flex items-center gap-2 rounded-lg border border-ink-200 bg-white px-3 py-1.5 text-sm"
              >
                <span className="text-ink-500">{bucket} days</span>
                <strong className="numeric text-ink-900">{count}</strong>
              </span>
            ))}
          </div>
        </Panel>
      )}

      <Panel className="mb-4 p-3">
        <form method="GET" className="flex flex-wrap items-center gap-2">
          <div className="relative min-w-0 flex-1">
            <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-ink-400" aria-hidden />
            <input
              type="search"
              name="q"
              defaultValue={params.q ?? ''}
              placeholder="Chassis, engine or registration number…"
              aria-label="Search vehicles"
              className="h-9 w-full rounded-lg border border-ink-200 bg-white pl-9 pr-3 text-sm text-ink-900 shadow-sm placeholder:text-ink-400 focus:border-brand-400 focus:outline-none focus:ring-2 focus:ring-brand-500/20"
            />
          </div>

          <select name="status" defaultValue={status} aria-label="Status"
            className="h-9 rounded-lg border border-ink-200 bg-white px-2 text-sm text-ink-700 shadow-sm">
            <option value="IN_STOCK">In stock</option>
            <option value="ALL">All statuses</option>
            <option value="BOOKED">Booked</option>
            <option value="SOLD_PENDING_DELIVERY">Sold, awaiting delivery</option>
            <option value="DELIVERED">Delivered</option>
            <option value="TRANSFERRED">Transferred</option>
          </select>

          {context.accessibleBranches.length > 0 && (
            <select name="branch" defaultValue={params.branch ?? 'all'} aria-label="Branch"
              className="h-9 rounded-lg border border-ink-200 bg-white px-2 text-sm text-ink-700 shadow-sm">
              {context.hasAllBranchAccess && <option value="all">All branches</option>}
              {context.accessibleBranches.map((b) => (
                <option key={b.id} value={b.id}>{b.name}</option>
              ))}
            </select>
          )}

          <select name="model" defaultValue={modelId ?? ''} aria-label="Model"
            className="h-9 rounded-lg border border-ink-200 bg-white px-2 text-sm text-ink-700 shadow-sm">
            <option value="">All models</option>
            {models.map((m) => (
              <option key={m.id} value={m.id}>{m.brand} {m.name}</option>
            ))}
          </select>

          <Button type="submit" variant="secondary" size="sm">Search</Button>
        </form>
      </Panel>

      <DataTable
        columns={columns}
        rows={result.rows}
        getRowKey={(row) => row.id}
        caption="Vehicle stock"
        emptyMessage={
          params.q
            ? `No vehicle matches “${params.q}”.`
            : 'No vehicles in stock. Upload a stock file to get started.'
        }
        maxHeight="40rem"
      />

      {result.pageCount > 1 && (
        <div className="mt-3 flex items-center justify-between text-sm text-ink-500">
          <span>Page {result.page} of {result.pageCount} · {formatNumber(result.total)} vehicles</span>
          <div className="flex gap-2">
            <Button variant="secondary" size="sm" disabled={result.page <= 1} asChild={result.page > 1}>
              {result.page > 1 ? <Link href={pageHref(result.page - 1)}>Previous</Link> : <span>Previous</span>}
            </Button>
            <Button variant="secondary" size="sm" disabled={result.page >= result.pageCount} asChild={result.page < result.pageCount}>
              {result.page < result.pageCount ? <Link href={pageHref(result.page + 1)}>Next</Link> : <span>Next</span>}
            </Button>
          </div>
        </div>
      )}
    </div>
  );
}

function Stat({
  icon: Icon,
  label,
  value,
  tone,
}: {
  readonly icon: typeof Bike;
  readonly label: string;
  readonly value: string;
  readonly tone: 'positive' | 'info' | 'warning' | 'accent';
}) {
  const tones: Record<string, string> = {
    positive: 'bg-positive-50 text-positive-600',
    info: 'bg-brand-50 text-brand-600',
    warning: 'bg-warning-50 text-warning-600',
    accent: 'bg-accent-50 text-accent-600',
  };
  return (
    <Panel className="flex items-center gap-3 p-4">
      <span className={`flex size-9 shrink-0 items-center justify-center rounded-xl ${tones[tone]}`}>
        <Icon className="size-4" aria-hidden />
      </span>
      <span className="min-w-0">
        <span className="block truncate text-[12px] text-ink-500">{label}</span>
        <span className="numeric block text-left text-lg font-semibold text-ink-900">{value}</span>
      </span>
    </Panel>
  );
}
