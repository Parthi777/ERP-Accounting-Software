import type { Metadata } from 'next';

import { getRecentBills } from '@/server/services/billing/quick-bill-service';
import { requirePermission } from '@/server/auth/tenant-context';
import { PageHeader } from '@/components/data-table/data-table';
import { QuickBillForm } from '@/components/billing/quick-bill-form';
import { BillsTable } from '@/components/billing/bills-table';

export const metadata: Metadata = { title: 'Service billing' };
export const dynamic = 'force-dynamic';

/**
 * Service billing as the workshop runs it (0088): customer name, vehicle
 * number and mobile — matched to an earlier customer where one exists — and a
 * value for spares, labour, water wash and other consumables. No job card.
 */
export default async function ServiceBillingPage() {
  const context = await requirePermission('service.billing.create');
  const bills = await getRecentBills('SERVICE');

  return (
    <div className="space-y-5">
      <PageHeader title="Service billing" description="Name, vehicle number and mobile; the values for spares, labour, water wash and consumables. Saving posts the bill and the receipt." />
      <QuickBillForm kind="SERVICE" branches={context.accessibleBranches.map((b) => ({ id: b.id, name: b.name }))}
        defaultBranchId={context.activeBranch?.id ?? null} />
      <BillsTable rows={bills} showVehicle />
    </div>
  );
}
