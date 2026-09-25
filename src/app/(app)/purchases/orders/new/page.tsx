import type { Metadata } from 'next';

import { requirePermission } from '@/server/auth/tenant-context';
import { getPurchaseGstRates, getPurchasePickers } from '@/server/services/purchases/purchase-service';
import { PageHeader } from '@/components/data-table/data-table';
import { PurchaseOrderForm } from '@/components/purchases/purchase-order-forms';
import { getItemUnits } from '@/server/services/masters/item-structure-service';

export const metadata: Metadata = { title: 'New purchase order' };
export const dynamic = 'force-dynamic';

export default async function NewPurchaseOrderPage() {
  const context = await requirePermission('purchases.create');
  const [pickers, gstRates, itemUnits] = await Promise.all([getPurchasePickers(), getPurchaseGstRates(), getItemUnits()]);

  return (
    <div className="mx-auto max-w-5xl">
      <PageHeader
        title="New purchase order"
        description={`Accessories and spares to order for ${context.activeBranch?.name ?? 'your branch'}. An order posts nothing; stock comes in when goods are received against it.`}
      />
      <PurchaseOrderForm
        suppliers={pickers.suppliers}
        items={pickers.items.map((i) => ({ id: i.id, label: i.label, standardCost: i.standardCost }))}
        gstRates={gstRates}
        itemUnits={itemUnits}
      />
    </div>
  );
}
