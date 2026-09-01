import type { Metadata } from 'next';
import { notFound } from 'next/navigation';

import { requirePermission } from '@/server/auth/tenant-context';
import { getPickerOptions, getMasterRecord } from '@/server/services/masters/masters-service';
import { PageHeader } from '@/components/data-table/data-table';
import { MasterForm } from '@/components/forms/master-form';

export const metadata: Metadata = { title: 'Edit Tax code' };
export const dynamic = 'force-dynamic';

export default async function Page({ params }: { params: Promise<{ id: string }> }) {
  await requirePermission('masters.tax.manage');
  const { id } = await params;
  const record = await getMasterRecord('tax', id);
  if (!record) notFound();
  const pickers = await getPickerOptions();

  const groups = [
    {
      title: 'Identity',
      fields: [
        { name: 'code', label: 'Tax code', type: 'text' as const, required: true, mono: true, maxLength: 30, placeholder: 'GST28' },
        { name: 'name', label: 'Name', type: 'text' as const, required: true, placeholder: 'GST 28%' },
        { name: 'hsn_code_id', label: 'HSN / SAC', type: 'select' as const, wide: true,
          options: pickers.hsn.map((o) => ({ value: o.id, label: o.label })) },
      ],
    },
    {
      title: 'Rates',
      description: 'IGST is not entered: the database requires it to equal CGST + SGST, so it is derived on save.',
      fields: [
        { name: 'cgst_rate', label: 'CGST', type: 'number' as const, required: true, step: '0.001', suffix: '%' },
        { name: 'sgst_rate', label: 'SGST', type: 'number' as const, required: true, step: '0.001', suffix: '%' },
        { name: 'cess_rate', label: 'Cess', type: 'number' as const, step: '0.001', suffix: '%' },
      ],
    },
    {
      title: 'Validity',
      description: 'Leave the end date empty for the rate currently in force.',
      fields: [
        { name: 'effective_from', label: 'Effective from', type: 'date' as const, required: true },
        { name: 'effective_to', label: 'Effective to', type: 'date' as const },
        { name: 'status', label: 'Status', type: 'select' as const, required: true, options: [
          { value: 'ACTIVE', label: 'Active' }, { value: 'INACTIVE', label: 'Inactive' },
        ] },
      ],
    },
  ];

  return (
    <div className="mx-auto max-w-3xl">
      <PageHeader title="Edit Tax code" />
      <MasterForm
        kind="tax"
        mode="edit"
        recordId={id}
        groups={groups}
        defaultValues={record}
        returnTo="/masters/tax"
        title="tax code"
      />
    </div>
  );
}
