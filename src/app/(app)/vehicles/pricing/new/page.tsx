import type { Metadata } from 'next';
import Link from 'next/link';
import { ArrowLeft } from 'lucide-react';

import { requirePermission } from '@/server/auth/tenant-context';
import { getVehicleModels, getVehicleVariants, getPickerOptions } from '@/server/services/masters/masters-service';
import { PageHeader } from '@/components/data-table/data-table';
import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { PriceForm } from '@/components/vehicles/price-form';

export const metadata: Metadata = { title: 'New price version' };
export const dynamic = 'force-dynamic';

export default async function NewPricePage() {
  const context = await requirePermission('vehicles.pricing.manage');
  const [models, variants, pickers] = await Promise.all([
    getVehicleModels(),
    getVehicleVariants(),
    getPickerOptions(),
  ]);

  return (
    <div className="mx-auto max-w-4xl">
      <Button variant="ghost" size="sm" asChild className="-ml-2 mb-2">
        <Link href="/vehicles/pricing"><ArrowLeft aria-hidden />Price history</Link>
      </Button>

      <PageHeader
        title="New price version"
        description="This supersedes the current price rather than replacing it. The old version stays readable."
      />

      {models.length === 0 ? (
        <Panel className="p-6 text-sm text-ink-600">
          No vehicle models exist yet. Create one under{' '}
          <Link href="/vehicles/models" className="text-brand-600 hover:underline">Vehicle Models</Link>{' '}
          first — a price has to attach to something.
        </Panel>
      ) : (
        <PriceForm
          models={models.map((m) => ({ id: m.id, label: `${m.brand} ${m.name}` }))}
          variants={variants.map((v) => ({ id: v.id, label: v.name, modelId: v.model_id }))}
          branches={context.accessibleBranches.map((b) => ({ id: b.id, label: b.name }))}
          taxCodes={pickers.taxCodes}
          canSeeCost={context.permissions.has('vehicles.view_cost')}
        />
      )}
    </div>
  );
}
