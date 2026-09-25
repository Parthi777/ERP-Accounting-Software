import type { Metadata } from 'next';

import { getRecentBills } from '@/server/services/billing/quick-bill-service';
import { requirePermission } from '@/server/auth/tenant-context';
import { PageHeader } from '@/components/data-table/data-table';
import { QuickBillForm } from '@/components/billing/quick-bill-form';
import { BillsTable } from '@/components/billing/bills-table';

export const metadata: Metadata = { title: 'Counter sales' };
export const dynamic = 'force-dynamic';

/**
 * Counter sales (0088): the cashier types the product name and the amount the
 * customer pays. No stock is picked or moved; the accountant keeps stock right
 * by periodic counts.
 */
export default async function CounterSalesPage() {
  const context = await requirePermission('inventory.counter_sale.create');
  const bills = await getRecentBills('COUNTER');

  return (
    <div className="space-y-5">
      <PageHeader title="Counter sales" description="Type the product and the amount paid. Saving posts the sale and the receipt, ready to print." />
      <QuickBillForm kind="COUNTER" branches={context.accessibleBranches.map((b) => ({ id: b.id, name: b.name }))}
        defaultBranchId={context.activeBranch?.id ?? null} />
      <BillsTable rows={bills} showVehicle={false} />
    </div>
  );
}
