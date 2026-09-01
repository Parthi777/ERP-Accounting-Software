import type { Metadata } from 'next';
import Link from 'next/link';
import { ArrowLeft } from 'lucide-react';

import { getCashDay, getContraAccounts } from '@/server/services/cash/cash-service';
import { getCustomerOptions } from '@/server/services/customers/customer-service';
import { requirePermission } from '@/server/auth/tenant-context';
import { PageHeader } from '@/components/data-table/data-table';
import { CashEntryForm } from '@/components/cash/cash-entry-form';
import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'Cash receipt' };
export const dynamic = 'force-dynamic';

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<{ date?: string }>;
}) {
  await requirePermission('cashbook.receipts.create');
  const params = await searchParams;
  const date = params.date ?? new Date().toISOString().slice(0, 10);

  const [day, accounts, customers] = await Promise.all([
    getCashDay({ date }),
    getContraAccounts('RECEIPT'),
    getCustomerOptions(),
  ]);

  if (!day) {
    return (
      <>
        <PageHeader title="Cash receipt" />
        <Panel className="p-6">
          <p className="text-sm text-ink-700">Select a branch before recording cash.</p>
        </Panel>
      </>
    );
  }

  return (
    <>
      <PageHeader
        title="Cash receipt"
        description={`Money in at ${day.branchName} on ${formatDate(day.businessDate)}.`}
        action={
          <Button variant="secondary" size="sm" asChild>
            <Link href={`/cash-book?date=${date}`}>
              <ArrowLeft aria-hidden />
              Cash book
            </Link>
          </Button>
        }
      />

      <div className="max-w-3xl">
        <CashEntryForm
          direction="RECEIPT"
          accounts={accounts}
          customers={customers}
          businessDate={day.businessDate}
          branchName={day.branchName}
          currentBalance={day.expectedClosing}
          locked={day.status === 'CLOSED'}
        />
      </div>
    </>
  );
}
