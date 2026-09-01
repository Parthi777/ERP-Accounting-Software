import type { Metadata } from 'next';

import {
  getCustomerLedger,
  getLedgerCustomerOptions,
} from '@/server/services/accounting/ledger-service';
import { requirePermission } from '@/server/auth/tenant-context';
import { PageHeader } from '@/components/data-table/data-table';
import { PartyLedgerView, CUSTOMER_LEDGER_LABELS } from '@/components/accounting/party-ledger-view';
import { monthRange } from '@/lib/period';

export const metadata: Metadata = { title: 'Customer ledger' };
export const dynamic = 'force-dynamic';

/**
 * Spec §9 lists Customer Ledger under both Customers and Accounting, and spec
 * §11 makes it part of the customer 360. They are the same statement, but the
 * two routes are gated differently — `customers.view_ledger` here, so a cashier
 * can check what someone owes without holding accounting permissions — so this
 * renders the shared view rather than redirecting to the accounting route the
 * user may not be allowed to open.
 */
export default async function Page({
  searchParams,
}: {
  searchParams: Promise<{ customer?: string; from?: string; to?: string }>;
}) {
  await requirePermission('customers.view_ledger');
  const params = await searchParams;
  const { from, to } = monthRange(params.from, params.to);
  const customerId = params.customer ?? '';

  const [customers, ledger] = await Promise.all([
    getLedgerCustomerOptions(),
    customerId ? getCustomerLedger({ customerId, from, to }) : Promise.resolve(null),
  ]);

  return (
    <>
      <PageHeader
        title="Customer ledger"
        description="A customer's running account: what was invoiced, what was received, and what is outstanding (spec §11)."
        count={ledger?.lines.length}
      />

      <PartyLedgerView
        basePath="/customers/ledger"
        paramName="customer"
        ledger={ledger}
        options={customers}
        selectedId={customerId}
        from={from}
        to={to}
        labels={CUSTOMER_LEDGER_LABELS}
        detailHref={(l) => `/customers/${l.partyId}`}
      />
    </>
  );
}
