import type { Metadata } from 'next';
import Link from 'next/link';
import { ArrowLeft } from 'lucide-react';

import { requirePermission } from '@/server/auth/tenant-context';
import { openingBalanceTemplate, openingBillTemplate } from '@/server/services/accounting/opening-balance-import';
import { OpeningBalanceImport } from '@/components/accounting/opening-balance-import';
import { PageHeader } from '@/components/data-table/data-table';
import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';

export const metadata: Metadata = { title: 'Opening balances' };
export const dynamic = 'force-dynamic';

export default async function OpeningBalancesPage() {
  await requirePermission('accounting.journals.post');

  return (
    <>
      <PageHeader
        title="Opening balances"
        description="What customers owed and what was owed to suppliers on the day you switched (spec §24)."
        action={
          <Button variant="secondary" size="sm" asChild>
            <Link href="/accounting/trial-balance"><ArrowLeft aria-hidden />Trial balance</Link>
          </Button>
        }
      />

      <Panel className="mb-4 p-4">
        <p className="text-sm text-ink-700">
          Each upload posts <strong>one journal</strong> covering every party in the file, balanced
          against <strong>3300 Opening Balance Equity</strong>. Choose <strong>Bill-wise</strong> to
          enter each unpaid bill with its number, date and due date, so it is settled and aged on its own.
        </p>
        <p className="mt-2 text-sm text-ink-600">
          One document rather than one per party, so a cut-over that turns out wrong — and a first
          attempt usually does — is a single reversal instead of several hundred, and the trial
          balance is never half-migrated in between.
        </p>
        <p className="mt-2 text-sm text-ink-600">
          Import the customer and supplier masters first: a code the file names but the master does
          not have stops the whole upload rather than being skipped, because a skipped party would
          surface later as an unexplained equity balance.
        </p>
      </Panel>

      <OpeningBalanceImport
        customerTemplate={openingBalanceTemplate('CUSTOMER')}
        supplierTemplate={openingBalanceTemplate('SUPPLIER')}
        customerBillTemplate={openingBillTemplate('CUSTOMER')}
        supplierBillTemplate={openingBillTemplate('SUPPLIER')}
      />
    </>
  );
}
