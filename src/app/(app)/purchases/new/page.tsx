import type { Metadata } from 'next';
import Link from 'next/link';
import { ArrowLeft } from 'lucide-react';

import { getPurchasePickers } from '@/server/services/purchases/purchase-service';
import { requirePermission } from '@/server/auth/tenant-context';
import { PageHeader } from '@/components/data-table/data-table';
import { PurchaseBillForm } from '@/components/purchases/purchase-bill-form';
import { Button } from '@/components/ui/button';

export const metadata: Metadata = { title: 'New purchase bill' };
export const dynamic = 'force-dynamic';

export default async function Page() {
  await requirePermission('purchases.create');
  const pickers = await getPurchasePickers();

  return (
    <>
      <PageHeader
        title="New purchase bill"
        description="Record what a supplier billed. Lines are added next, on the draft itself."
        action={
          <Button variant="secondary" size="sm" asChild>
            <Link href="/purchases"><ArrowLeft aria-hidden />Purchase bills</Link>
          </Button>
        }
      />
      <div className="max-w-3xl">
        <PurchaseBillForm
          suppliers={pickers.suppliers}
          today={new Date().toISOString().slice(0, 10)}
        />
      </div>
    </>
  );
}
