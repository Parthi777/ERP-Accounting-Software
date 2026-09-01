import type { Metadata } from 'next';
import {
  Bike,
  BookMarked,
  Building2,
  CircleDollarSign,
  Landmark,
  Layers,
  Package,
  Receipt,
  TrendingUp,
  Truck,
  Wallet,
  Wrench,
} from 'lucide-react';

import { requireTenantContext } from '@/server/auth/tenant-context';
import { getDashboard } from '@/server/services/dashboard/dashboard-service';
import { formatDateRange } from '@/lib/format';
import { Panel, PanelContent, PanelHeader, PanelTitle } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { KpiCard } from '@/components/dashboard/kpi-card';
import { RevenueMixChart, RevenueTrendChart } from '@/components/dashboard/revenue-charts';
import { DashboardFilters } from '@/app/(app)/dashboard/dashboard-filters';

export const metadata: Metadata = { title: 'Dashboard' };

// KPI values come from live journal data; never serve a cached dashboard.
export const dynamic = 'force-dynamic';

const ICONS: Record<string, typeof Bike> = {
  vehicle_sales_units: Bike,
  vehicle_sales_value: CircleDollarSign,
  bookings: BookMarked,
  booking_advance: Wallet,
  deliveries: Truck,
  service_revenue: Wrench,
  vehicle_stock_qty: Bike,
  vehicle_stock_value: Layers,
  accessory_stock_qty: Package,
  accessory_stock_value: Package,
  spare_stock_qty: Package,
  spare_stock_value: Package,
  finance_units: Landmark,
  finance_amount: Landmark,
  cash_balance: Wallet,
  bank_balance: Building2,
  receivables: TrendingUp,
  payables: Receipt,
};

export default async function DashboardPage({
  searchParams,
}: {
  searchParams: Promise<{ from?: string; to?: string; branch?: string }>;
}) {
  const context = await requireTenantContext();
  const params = await searchParams;

  const { from, to } = resolvePeriod(params.from, params.to);
  const branchId = params.branch === 'all' ? null : (params.branch ?? null);

  const data = await getDashboard({ from, to, branchId });

  return (
    <div className="space-y-5">
      {/* Greeting + filters */}
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div>
          <h1 className="text-xl font-bold tracking-tight text-ink-900">
            {greeting()}, {context.fullName.split(' ')[0]}
          </h1>
          <p className="mt-0.5 text-sm text-ink-500">
            {data.branchLabel} · {formatDateRange(from, to)}
          </p>
        </div>

        <DashboardFilters
          branches={context.accessibleBranches.map((branch) => ({
            id: branch.id,
            code: branch.code,
            name: branch.name,
          }))}
          canViewAllBranches={context.hasAllBranchAccess}
          from={from}
          to={to}
          branchId={branchId}
        />
      </div>

      {!data.ledgerHasData && (
        <Panel className="flex items-start gap-3 p-4">
          <Badge variant="info">No data</Badge>
          <p className="text-sm text-ink-600">
            No posted journal entries fall in this period, so every ledger-backed figure reads zero.
            Apply <code className="rounded bg-ink-100 px-1 py-0.5 text-xs">supabase/seed-demo-ledger.sql</code>{' '}
            for demo figures, or widen the date range.
          </p>
        </Panel>
      )}

      {/* Row 1 — headline KPIs (spec §54) */}
      <section aria-label="Key performance indicators">
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-6">
          {data.primary.map((kpi) => (
            <KpiCard key={kpi.key} kpi={kpi} icon={ICONS[kpi.key]} />
          ))}
        </div>
      </section>

      {/* Row 2 — stock and finance */}
      <section aria-label="Stock and finance">
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          {data.secondary.map((kpi) => (
            <KpiCard key={kpi.key} kpi={kpi} icon={ICONS[kpi.key]} tone="accent" />
          ))}
        </div>
      </section>

      {/* Row 3 — charts */}
      <section className="grid gap-4 lg:grid-cols-3" aria-label="Revenue analysis">
        <Panel className="lg:col-span-2">
          <PanelHeader>
            <div>
              <PanelTitle>Revenue Overview</PanelTitle>
              <p className="text-xs text-ink-500">Posted revenue by day, from the general ledger</p>
            </div>
          </PanelHeader>
          <PanelContent>
            <RevenueTrendChart data={data.revenueTrend} />
          </PanelContent>
        </Panel>

        <Panel>
          <PanelHeader>
            <div>
              <PanelTitle>Revenue by Category</PanelTitle>
              <p className="text-xs text-ink-500">Vehicles, accessories, spares and service</p>
            </div>
          </PanelHeader>
          <PanelContent>
            <RevenueMixChart data={data.revenueMix} />
          </PanelContent>
        </Panel>
      </section>

      {/* Row 4 — cash, bank, working capital */}
      <section aria-label="Cash and bank">
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          {data.financial.map((kpi) => (
            <KpiCard
              key={kpi.key}
              kpi={kpi}
              icon={ICONS[kpi.key]}
              tone={kpi.key === 'payables' ? 'danger' : 'positive'}
            />
          ))}
        </div>
      </section>

      {/* Row 5 — margin and profitability, Owner/Accounts only (spec §10) */}
      {data.canSeeMargin && data.margin.length > 0 && (
        <section aria-label="Margin and profitability">
          <Panel className="p-4">
            <div className="mb-3 flex items-center gap-2">
              <PanelTitle>Margin & Profitability</PanelTitle>
              <Badge variant="warning">Restricted</Badge>
              <span className="text-xs text-ink-400">
                Visible to Accounts and Owner roles only
              </span>
            </div>
            <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
              {data.margin.map((kpi) => (
                <div key={kpi.key} className="rounded-lg border border-ink-200/70 bg-white/60 p-3">
                  <p className="truncate text-[12px] text-ink-500">{kpi.label}</p>
                  <p className="numeric mt-1 text-left text-lg font-semibold text-ink-900">
                    {kpi.display}
                  </p>
                </div>
              ))}
            </div>
          </Panel>
        </section>
      )}
    </div>
  );
}

/** Defaults to the current month when no range is supplied. */
function resolvePeriod(from?: string, to?: string): { from: string; to: string } {
  const isIsoDate = (value?: string) => Boolean(value && /^\d{4}-\d{2}-\d{2}$/.test(value));

  if (isIsoDate(from) && isIsoDate(to)) {
    return { from: from!, to: to! };
  }

  const now = new Date();
  const start = new Date(now.getFullYear(), now.getMonth(), 1);
  const end = new Date(now.getFullYear(), now.getMonth() + 1, 0);
  return { from: toIso(start), to: toIso(end) };
}

function toIso(date: Date): string {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
}

function greeting(): string {
  const hour = new Date().getHours();
  if (hour < 12) return 'Good morning';
  if (hour < 17) return 'Good afternoon';
  return 'Good evening';
}
