import type { Metadata } from 'next';
import { notFound } from 'next/navigation';

import { requirePermission } from '@/server/auth/tenant-context';
import { getPickerOptions, getMasterRecord } from '@/server/services/masters/masters-service';
import { PageHeader } from '@/components/data-table/data-table';
import { MasterForm } from '@/components/forms/master-form';

export const metadata: Metadata = { title: 'Edit Variant' };
export const dynamic = 'force-dynamic';

export default async function Page({ params }: { params: Promise<{ id: string }> }) {
  await requirePermission('vehicles.models.manage');
  const { id } = await params;
  const record = await getMasterRecord('vehicle_variant', id);
  if (!record) notFound();
  const pickers = await getPickerOptions();

  const groups = [
    {
      title: 'Variant',
      fields: [
        { name: 'model_id', label: 'Model', type: 'select' as const, required: true, wide: true,
          options: pickers.models.map((o) => ({ value: o.id, label: o.label })) },
        { name: 'name', label: 'Variant name', type: 'text' as const, required: true, placeholder: 'Drum' },
        { name: 'variant_code', label: 'Variant code', type: 'text' as const, required: true, mono: true, maxLength: 30, placeholder: 'JUP110-DRM' },
        { name: 'status', label: 'Status', type: 'select' as const, required: true, options: [
          { value: 'ACTIVE', label: 'Active' }, { value: 'DISCONTINUED', label: 'Discontinued' },
        ] },
      ],
    },
    {
      title: 'Specification',
      fields: [
        { name: 'engine_cc', label: 'Engine', type: 'number' as const, step: '0.1', suffix: 'cc' },
        { name: 'transmission', label: 'Transmission', type: 'text' as const },
        { name: 'brake_type', label: 'Brake type', type: 'text' as const },
        { name: 'start_type', label: 'Start type', type: 'text' as const },
      ],
    },
  ];

  return (
    <div className="mx-auto max-w-3xl">
      <PageHeader title="Edit Variant" />
      <MasterForm
        kind="vehicle_variant"
        mode="edit"
        recordId={id}
        groups={groups}
        defaultValues={record}
        returnTo="/vehicles/variants"
        title="variant"
      />
    </div>
  );
}
