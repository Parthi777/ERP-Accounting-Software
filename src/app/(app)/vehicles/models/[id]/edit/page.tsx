import type { Metadata } from 'next';
import { notFound } from 'next/navigation';

import { requirePermission } from '@/server/auth/tenant-context';
import { getPickerOptions, getMasterRecord } from '@/server/services/masters/masters-service';
import { PageHeader } from '@/components/data-table/data-table';
import { MasterForm } from '@/components/forms/master-form';

export const metadata: Metadata = { title: 'Edit Vehicle model' };
export const dynamic = 'force-dynamic';

export default async function Page({ params }: { params: Promise<{ id: string }> }) {
  await requirePermission('vehicles.models.manage');
  const { id } = await params;
  const record = await getMasterRecord('vehicle_model', id);
  if (!record) notFound();
  const pickers = await getPickerOptions();

  const groups = [
    {
      title: 'Model',
      fields: [
        { name: 'brand', label: 'Brand', type: 'text' as const, required: true, placeholder: 'TVS' },
        { name: 'name', label: 'Model name', type: 'text' as const, required: true, placeholder: 'Jupiter 110' },
        { name: 'model_code', label: 'Model code', type: 'text' as const, required: true, mono: true, maxLength: 30, placeholder: 'JUP110' },
        { name: 'category', label: 'Category', type: 'select' as const, required: true, options: [
          { value: 'SCOOTER', label: 'Scooter' }, { value: 'MOTORCYCLE', label: 'Motorcycle' },
          { value: 'MOPED', label: 'Moped' }, { value: 'ELECTRIC', label: 'Electric' },
          { value: 'THREE_WHEELER', label: 'Three wheeler' },
        ] },
        { name: 'fuel_type', label: 'Fuel', type: 'select' as const, required: true, options: [
          { value: 'PETROL', label: 'Petrol' }, { value: 'ELECTRIC', label: 'Electric' },
          { value: 'CNG', label: 'CNG' }, { value: 'HYBRID', label: 'Hybrid' },
        ] },
        { name: 'status', label: 'Status', type: 'select' as const, required: true, options: [
          { value: 'ACTIVE', label: 'Active' }, { value: 'DISCONTINUED', label: 'Discontinued' },
        ] },
      ],
    },
    {
      title: 'Tax',
      fields: [
        { name: 'hsn_code_id', label: 'HSN code', type: 'select' as const,
          options: pickers.hsn.map((o) => ({ value: o.id, label: o.label })) },
        { name: 'tax_code', label: 'Tax code', type: 'select' as const,
          options: pickers.taxCodes.map((o) => ({ value: o.code, label: o.label })) },
      ],
    },
  ];

  return (
    <div className="mx-auto max-w-3xl">
      <PageHeader title="Edit Vehicle model" />
      <MasterForm
        kind="vehicle_model"
        mode="edit"
        recordId={id}
        groups={groups}
        defaultValues={record}
        returnTo="/vehicles/models"
        title="vehicle model"
      />
    </div>
  );
}
