import type { Metadata } from 'next';

import {
  getCustomerLedger,
  getLedgerCustomerOptions,
} from '@/server/services/accounting/ledger-service';
import { getPartySettlement } from '@/server/services/accounting/settlement-service';
import { requirePermission } from '@/server/auth/tenant-context';
import { PageHeader } from '@/components/data-table/data-table';
import { PartyLedgerView, CUSTOMER_LEDGER_LABELS } from '@/components/accounting/party-ledger-view';
import {
  PartySettlement,
  CUSTOMER_SETTLEMENT_LABELS,
} from '@/components/accounting/party-settlement';
import { ExportButtons } from '@/components/export/export-buttons';
import { monthRange } from '@/lib/period';

export const metadata: Metadata = { title: 'Customer ledger' };
export const dynamic = 'force-dynamic';

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<{ customer?: string; from?: string; to?: string }>;
}) {
  await requirePermission('accounting.ledgers.view');
  const params = await searchParams;
  const { from, to } = monthRange(params.from, params.to);
  const customerId = params.customer ?? '';

  const [customers, ledger, settlement] = await Promise.all([
    getLedgerCustomerOptions(),
    customerId ? getCustomerLedger({ customerId, from, to }) : Promise.resolve(null),
    // Deliberately not bounded by the date filter: a receipt taken in August can
    // settle a July invoice, and a settlement screen that only offered the
    // month on screen would make that unrecordable.
    customerId
      ? getPartySettlement({ partyType: 'CUSTOMER', partyId: customerId })
      : Promise.resolve(null),
  ]);

  return (
    <>
      <PageHeader
        title="Customer ledger"
        description="The subsidiary ledger, derived from party-tagged journal lines so it always agrees with the receivable control account (spec §41)."
        count={ledger?.lines.length}
        action={<ExportButtons report="customer-ledger" />}
      />

      <PartyLedgerView
        basePath="/accounting/customer-ledger"
        paramName="customer"
        ledger={ledger}
        options={customers}
        selectedId={customerId}
        from={from}
        to={to}
        labels={CUSTOMER_LEDGER_LABELS}
        detailHref={(l) => `/customers/${l.partyId}`}
      />

      {ledger && settlement && (
        <PartySettlement settlement={settlement} labels={CUSTOMER_SETTLEMENT_LABELS} />
      )}
    </>
  );
}
