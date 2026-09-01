import type { Metadata } from 'next';
import Link from 'next/link';
import { notFound } from 'next/navigation';
import { ArrowLeft } from 'lucide-react';

import {
  getServiceInvoice,
  getServiceItems,
} from '@/server/services/service/service-service';
import { requirePermission, hasPermission } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { PageHeader } from '@/components/data-table/data-table';
import { ServiceInvoiceEditor } from '@/components/service/invoice-editor';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'Service invoice' };
export const dynamic = 'force-dynamic';

const STATUS_TONE: Record<string, 'positive' | 'neutral' | 'danger' | 'warning'> = {
  DRAFT: 'warning',
  POSTED: 'positive',
  CANCELLED: 'danger',
  RETURNED: 'neutral',
};

export default async function Page({ params }: { params: Promise<{ id: string }> }) {
  const context = await requirePermission('service.jobcards.view');
  const { id } = await params;

  const invoice = await getServiceInvoice(id);
  if (!invoice) notFound();

  const canBill = hasPermission(context, 'service.billing.create');
  const supabase = await createSupabaseServerClient();

  const [items, taxCodes] = await Promise.all([
    canBill ? getServiceItems() : Promise.resolve([]),
    supabase.from('tax_codes').select('code, name').eq('status', 'ACTIVE').order('code'),
  ]);

  return (
    <>
      <Button variant="ghost" size="sm" asChild className="-ml-2 mb-2">
        <Link href="/service/billing"><ArrowLeft aria-hidden />Service bills</Link>
      </Button>

      <PageHeader
        title={invoice.number}
        description={
          [
            formatDate(invoice.invoiceDate),
            invoice.customerName,
            invoice.jobCardNumber ? `Job card ${invoice.jobCardNumber}` : null,
          ]
            .filter(Boolean)
            .join(' · ')
        }
        action={<Badge variant={STATUS_TONE[invoice.status] ?? 'neutral'}>{invoice.status}</Badge>}
      />

      <ServiceInvoiceEditor
        invoice={invoice}
        items={items.map((i) => ({ ...i, rate: i.rate as number }))}
        taxCodes={(taxCodes.data ?? []).map((t) => ({ code: t.code, label: `${t.code} · ${t.name}` }))}
        canBill={canBill}
        canCollect={hasPermission(context, 'service.payments.collect')}
      />
    </>
  );
}
