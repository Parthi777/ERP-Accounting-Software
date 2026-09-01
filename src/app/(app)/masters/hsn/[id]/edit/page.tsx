import type { Metadata } from 'next';
import { notFound } from 'next/navigation';

import { requirePermission } from '@/server/auth/tenant-context';
import { getMasterRecord } from '@/server/services/masters/masters-service';
import { PageHeader } from '@/components/data-table/data-table';
import { MasterForm } from '@/components/forms/master-form';

export const metadata: Metadata = { title: 'Edit HSN code' };
export const dynamic = 'force-dynamic';

export default async function Page({ params }: { params: Promise<{ id: string }> }) {
  await requirePermission('masters.hsn.manage');
  const { id } = await params;
  const record = await getMasterRecord('hsn', id);
  if (!record) notFound();

  const groups = [
    {
      title: 'Code',
      fields: [
        { name: 'code', label: 'HSN / SAC code', type: 'text' as const, required: true, mono: true, maxLength: 8, placeholder: '87112019', help: '4 to 8 digits.' },
        { name: 'code_type', label: 'Type', type: 'select' as const, required: true, options: [
          { value: 'HSN', label: 'HSN — goods' },
          { value: 'SAC', label: 'SAC — services' },
        ] },
        { name: 'description', label: 'Description', type: 'text' as const, required: true, wide: true },
        { name: 'status', label: 'Status', type: 'select' as const, required: true, options: [
          { value: 'ACTIVE', label: 'Active' }, { value: 'INACTIVE', label: 'Inactive' },
        ] },
      ],
    },
  ];

  return (
    <div className="mx-auto max-w-3xl">
      <PageHeader title="Edit HSN code" />
      <MasterForm
        kind="hsn"
        mode="edit"
        recordId={id}
        groups={groups}
        defaultValues={record}
        returnTo="/masters/hsn"
        title="hsn code"
      />
    </div>
  );
}
