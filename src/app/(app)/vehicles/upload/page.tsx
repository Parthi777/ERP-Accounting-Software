import type { Metadata } from 'next';
import Link from 'next/link';
import { ArrowLeft } from 'lucide-react';

import { requirePermission } from '@/server/auth/tenant-context';
import { getCatalogueLookup } from '@/server/services/vehicles/vehicle-service';
import { PageHeader } from '@/components/data-table/data-table';
import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { StockUpload } from '@/components/vehicles/stock-upload';

export const metadata: Metadata = { title: 'Upload vehicle stock' };
export const dynamic = 'force-dynamic';

export default async function UploadPage() {
  await requirePermission('vehicles.stock.upload');
  const catalogue = await getCatalogueLookup();

  const modelCodes = [...catalogue.models.keys()].slice(0, 12);
  const branchCodes = [...catalogue.branches.keys()];

  return (
    <div className="mx-auto max-w-5xl">
      <Button variant="ghost" size="sm" asChild className="-ml-2 mb-2">
        <Link href="/vehicles"><ArrowLeft aria-hidden />Vehicle stock</Link>
      </Button>

      <PageHeader
        title="Upload vehicle stock"
        description="Every row is validated before anything is written. A file with errors imports nothing."
      />

      {catalogue.models.size === 0 && (
        <Panel className="mb-4 p-4 text-sm text-ink-600">
          No vehicle models exist yet. Create at least one under{' '}
          <Link href="/vehicles/models" className="text-brand-600 hover:underline">Vehicle Models</Link>{' '}
          before uploading stock — the import matches rows by model code.
        </Panel>
      )}

      <StockUpload />

      <Panel className="mt-4 p-4">
        <h2 className="text-sm font-semibold text-ink-900">Codes this dealer accepts</h2>
        <p className="mt-1 text-xs text-ink-500">
          The import matches on these codes, not on names.
        </p>
        <dl className="mt-3 grid gap-4 sm:grid-cols-2">
          <div>
            <dt className="text-xs font-medium uppercase tracking-wide text-ink-400">Branch codes</dt>
            <dd className="mt-1 flex flex-wrap gap-1">
              {branchCodes.length === 0 ? (
                <span className="text-sm text-ink-400">None</span>
              ) : (
                branchCodes.map((c) => (
                  <code key={c} className="rounded bg-ink-100 px-1.5 py-0.5 text-xs text-ink-700">{c}</code>
                ))
              )}
            </dd>
          </div>
          <div>
            <dt className="text-xs font-medium uppercase tracking-wide text-ink-400">
              Model codes {catalogue.models.size > 12 && `(first 12 of ${catalogue.models.size})`}
            </dt>
            <dd className="mt-1 flex flex-wrap gap-1">
              {modelCodes.length === 0 ? (
                <span className="text-sm text-ink-400">None</span>
              ) : (
                modelCodes.map((c) => (
                  <code key={c} className="rounded bg-ink-100 px-1.5 py-0.5 text-xs text-ink-700">{c}</code>
                ))
              )}
            </dd>
          </div>
        </dl>
      </Panel>
    </div>
  );
}
