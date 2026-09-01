import type { Metadata } from 'next';
import Link from 'next/link';
import { notFound } from 'next/navigation';
import { ArrowLeft } from 'lucide-react';

import { getVehicle } from '@/server/services/vehicles/vehicle-service';
import { requireTenantContext } from '@/server/auth/tenant-context';
import { Panel, PanelContent, PanelHeader, PanelTitle } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { formatINR, fromDb } from '@/lib/money';
import { formatDate, formatDateTime } from '@/lib/format';

export const metadata: Metadata = { title: 'Vehicle' };
export const dynamic = 'force-dynamic';

const STATUS_TONE: Record<string, 'positive' | 'info' | 'warning' | 'neutral' | 'danger'> = {
  IN_STOCK: 'positive',
  BOOKED: 'info',
  SOLD_PENDING_DELIVERY: 'warning',
  DELIVERED: 'neutral',
  TRANSFERRED: 'neutral',
  CANCELLED: 'danger',
};

export default async function VehicleDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const context = await requireTenantContext();
  const detail = await getVehicle(id);

  if (!detail) {
    notFound();
  }

  const { vehicle, modelLabel, variantName, branchName, movements } = detail;
  const canSeeCost = context.permissions.has('vehicles.view_cost');

  const fields: { label: string; value: string }[] = [
    { label: 'Chassis number', value: vehicle.chassis_no },
    { label: 'Engine number', value: vehicle.engine_no },
    { label: 'Key number', value: vehicle.key_no ?? '—' },
    { label: 'Model', value: modelLabel },
    { label: 'Variant', value: variantName ?? '—' },
    { label: 'Branch', value: branchName },
    { label: 'Registration', value: vehicle.registration_no ?? 'Not registered' },
    { label: 'Purchase invoice', value: vehicle.purchase_invoice ?? '—' },
    { label: 'Purchase date', value: formatDate(vehicle.purchase_date) },
    { label: 'In stock since', value: formatDate(vehicle.stock_date) },
    ...(canSeeCost
      ? [{ label: 'Purchase cost', value: formatINR(fromDb(vehicle.purchase_cost)) }]
      : []),
  ];

  return (
    <div>
      <Button variant="ghost" size="sm" asChild className="-ml-2 mb-2">
        <Link href="/vehicles"><ArrowLeft aria-hidden />Vehicle stock</Link>
      </Button>

      <div className="mb-4 flex flex-wrap items-start justify-between gap-3">
        <div>
          <div className="flex items-center gap-2">
            <h1 className="font-mono text-xl font-bold tracking-tight text-ink-900">{vehicle.chassis_no}</h1>
            <Badge variant={STATUS_TONE[vehicle.status] ?? 'neutral'}>
              {vehicle.status.replace(/_/g, ' ')}
            </Badge>
          </div>
          <p className="mt-0.5 text-sm text-ink-500">
            {modelLabel}{variantName ? ` · ${variantName}` : ''}
          </p>
        </div>
      </div>

      <div className="grid gap-4 lg:grid-cols-3">
        <Panel className="lg:col-span-2">
          <PanelHeader><PanelTitle>Vehicle</PanelTitle></PanelHeader>
          <PanelContent>
            <dl className="grid gap-x-8 gap-y-4 sm:grid-cols-2">
              {fields.map((f) => (
                <div key={f.label}>
                  <dt className="text-xs font-medium uppercase tracking-wide text-ink-400">{f.label}</dt>
                  <dd className="mt-0.5 text-sm text-ink-900">{f.value}</dd>
                </div>
              ))}
            </dl>
          </PanelContent>
        </Panel>

        <Panel>
          <PanelHeader>
            <div>
              <PanelTitle>Movement history</PanelTitle>
              <p className="text-xs text-ink-500">Written by the database, never by hand</p>
            </div>
          </PanelHeader>
          <PanelContent>
            {movements.length === 0 ? (
              <p className="text-sm text-ink-400">No movements recorded.</p>
            ) : (
              <ol className="space-y-3">
                {movements.map((m) => (
                  <li key={m.id} className="border-l-2 border-ink-200 pl-3">
                    <p className="text-sm font-medium text-ink-800">
                      {m.type.replace(/_/g, ' ')}
                      {m.fromStatus && m.toStatus && (
                        <span className="ml-1 font-normal text-ink-500">
                          {m.fromStatus.replace(/_/g, ' ')} → {m.toStatus.replace(/_/g, ' ')}
                        </span>
                      )}
                    </p>
                    <p className="text-xs text-ink-400">{formatDateTime(m.createdAt)}</p>
                    {m.narration && <p className="mt-0.5 text-xs text-ink-600">{m.narration}</p>}
                  </li>
                ))}
              </ol>
            )}
          </PanelContent>
        </Panel>
      </div>
    </div>
  );
}
