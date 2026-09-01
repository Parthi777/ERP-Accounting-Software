import type { Metadata } from 'next';

import { requirePermission } from '@/server/auth/tenant-context';
import { PageHeader } from '@/components/data-table/data-table';
import { MasterForm } from '@/components/forms/master-form';
import { SUPPLIER_FIELD_GROUPS } from '@/components/forms/supplier-fields';

export const metadata: Metadata = { title: 'New supplier' };
export const dynamic = 'force-dynamic';

export default async function Page() {
  await requirePermission('masters.suppliers.manage');

  return (
    <div className="mx-auto max-w-3xl">
      <PageHeader
        title="New supplier"
        description="The supplier code is issued by the database on save, so it is unique and cannot be typed in."
      />
      <MasterForm
        kind="supplier"
        mode="create"
        groups={SUPPLIER_FIELD_GROUPS}
        defaultValues={{ status: 'ACTIVE', supplier_type: 'GOODS', credit_days: 0 }}
        returnTo="/masters/suppliers"
        title="supplier"
      />
    </div>
  );
}
