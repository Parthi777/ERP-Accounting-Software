import type { Metadata } from 'next';
import Link from 'next/link';
import { notFound } from 'next/navigation';
import { ArrowLeft } from 'lucide-react';

import {
  getServiceInvoice,
  getServiceItems,
  getTaxCodeOptions,
} from '@/server/services/service/service-service';
import { requirePermission, hasPermission } from '@/server/auth/tenant-context';
import { PageHeader } from '@/components/data-table/data-table';
import { ServiceInvoiceEditor } from '@/components/service/invoice-editor';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'Counter sale' };
export const dynamic = 'force-dynamic';

const STATUS_TONE: Record<string, 'positive' | 'info' | 'neutral' | 'warning' | 'danger'> = {
  DRAFT: 'warning',
  POSTED: 'positive',
  CANCELLED: 'neutral',
  RETURNED: 'danger',
};

/**
 * A counter sale is a service invoice without a job card, so it is edited by the
 * same component — one billing screen, one set of rules about stock and posting
 * (spec §33, §60.18). Only the gate and the way back differ.
 */
export default async function Page({ params }: { params: Promise<{ id: string }> }) {
  const context = await requirePermission('inventory.counter_sale.create');
  const { id } = await params;

  const invoice = await getServiceInvoice(id);
  if (!invoice) notFound();

  const [items, taxCodes] = await Promise.all([getServiceItems(), getTaxCodeOptions()]);

  return (
    <>
      <Button variant="ghost" size="sm" asChild className="-ml-2 mb-2">
        <Link href="/inventory/counter-sales"><ArrowLeft aria-hidden />Counter sales</Link>
      </Button>

      <PageHeader
        title={invoice.number}
        description={[formatDate(invoice.invoiceDate), invoice.customerName ?? 'Walk-in']
          .filter(Boolean)
          .join(' · ')}
        action={<Badge variant={STATUS_TONE[invoice.status] ?? 'neutral'}>{invoice.status}</Badge>}
      />

      <ServiceInvoiceEditor
        invoice={invoice}
        items={items.map((i) => ({ ...i, rate: i.rate as number }))}
        taxCodes={taxCodes}
        canBill
        canCollect={hasPermission(context, 'service.payments.collect')}
      />
    </>
  );
}
