import type { Metadata } from 'next';
import { notFound } from 'next/navigation';

import { requirePermission } from '@/server/auth/tenant-context';
import { getMasterRecord } from '@/server/services/masters/masters-service';
import { PageHeader } from '@/components/data-table/data-table';
import { MasterForm } from '@/components/forms/master-form';
import { SUPPLIER_FIELD_GROUPS } from '@/components/forms/supplier-fields';

export const metadata: Metadata = { title: 'Edit supplier' };
export const dynamic = 'force-dynamic';

export default async function Page({ params }: { params: Promise<{ id: string }> }) {
  await requirePermission('masters.suppliers.manage');
  const { id } = await params;
  const record = await getMasterRecord('supplier', id);
  if (!record) notFound();

  return (
    <div className="mx-auto max-w-3xl">
      <PageHeader
        title="Edit supplier"
        description={
          typeof record.supplier_code === 'string' ? `${record.supplier_code}` : undefined
        }
      />
      <MasterForm
        kind="supplier"
        mode="edit"
        recordId={id}
        groups={SUPPLIER_FIELD_GROUPS}
        defaultValues={record}
        returnTo="/masters/suppliers"
        title="supplier"
      />
    </div>
  );
}
