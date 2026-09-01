import type { Metadata } from 'next';

import { requirePermission } from '@/server/auth/tenant-context';
import { PageHeader } from '@/components/data-table/data-table';
import { CustomerForm } from '@/components/forms/customer-form';

export const metadata: Metadata = { title: 'New customer' };
export const dynamic = 'force-dynamic';

export default async function NewCustomerPage() {
  const context = await requirePermission('customers.create');

  return (
    <div className="mx-auto max-w-3xl">
      <PageHeader
        title="New customer"
        description="The Customer ID is issued by the system once you save."
      />
      <CustomerForm
        mode="create"
        branches={context.accessibleBranches.map((b) => ({ id: b.id, name: b.name }))}
        defaultValues={{ origin_branch_id: context.activeBranch?.id }}
      />
    </div>
  );
}
