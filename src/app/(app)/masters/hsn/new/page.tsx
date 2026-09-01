import type { Metadata } from 'next';

import { requirePermission } from '@/server/auth/tenant-context';
import {  } from '@/server/services/masters/masters-service';
import { PageHeader } from '@/components/data-table/data-table';
import { MasterForm } from '@/components/forms/master-form';

export const metadata: Metadata = { title: 'New HSN code' };
export const dynamic = 'force-dynamic';

export default async function Page() {
  await requirePermission('masters.hsn.manage');

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
  const defaults = { code_type: 'HSN', status: 'ACTIVE' };

  return (
    <div className="mx-auto max-w-3xl">
      <PageHeader title="New HSN code" />
      <MasterForm
        kind="hsn"
        mode="create"
        groups={groups}
        defaultValues={defaults}
        returnTo="/masters/hsn"
        title="hsn code"
      />
    </div>
  );
}
