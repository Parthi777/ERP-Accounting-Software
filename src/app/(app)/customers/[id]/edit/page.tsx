import type { Metadata } from 'next';
import { notFound } from 'next/navigation';

import { getCustomer } from '@/server/services/customers/customer-service';
import { requirePermission } from '@/server/auth/tenant-context';
import { NotFoundError } from '@/server/errors';
import { PageHeader } from '@/components/data-table/data-table';
import { CustomerForm } from '@/components/forms/customer-form';

export const metadata: Metadata = { title: 'Edit customer' };
export const dynamic = 'force-dynamic';

export default async function EditCustomerPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const context = await requirePermission('customers.edit');

  let customer;
  try {
    customer = await getCustomer(id);
  } catch (error) {
    if (error instanceof NotFoundError) {
      notFound();
    }
    throw error;
  }

  return (
    <div className="mx-auto max-w-3xl">
      <PageHeader title="Edit customer" description={customer.name} />
      <CustomerForm
        mode="edit"
        customerId={customer.id}
        customerCode={customer.customer_code}
        branches={context.accessibleBranches.map((b) => ({ id: b.id, name: b.name }))}
        defaultValues={{
          name: customer.name,
          customer_type: customer.customer_type,
          mobile: customer.mobile,
          alternate_mobile: customer.alternate_mobile ?? '',
          email: customer.email ?? '',
          address_line1: customer.address_line1 ?? '',
          address_line2: customer.address_line2 ?? '',
          city: customer.city ?? '',
          state: customer.state ?? '',
          state_code: customer.state_code ?? '',
          pincode: customer.pincode ?? '',
          gstin: customer.gstin ?? '',
          pan: customer.pan ?? '',
          origin_branch_id: customer.origin_branch_id ?? '',
          notes: customer.notes ?? '',
          status: customer.status,
        }}
      />
    </div>
  );
}
