import type { Metadata } from 'next';

import {
  getSupplierLedger,
  getLedgerSupplierOptions,
} from '@/server/services/accounting/ledger-service';
import { requirePermission } from '@/server/auth/tenant-context';
import { PageHeader } from '@/components/data-table/data-table';
import { PartyLedgerView, SUPPLIER_LEDGER_LABELS } from '@/components/accounting/party-ledger-view';
import { monthRange } from '@/lib/period';

export const metadata: Metadata = { title: 'Supplier ledger' };
export const dynamic = 'force-dynamic';

/**
 * Spec §41. The same statement as the customer ledger and the same code behind
 * it — only the party and the sign's meaning differ. A supplier balance is
 * normally a credit, because the dealer owes them.
 *
 * Entries arrive here from any cash or bank payment tagged to the supplier, so
 * the ledger reconciles to Supplier Payables by construction.
 */
export default async function Page({
  searchParams,
}: {
  searchParams: Promise<{ supplier?: string; from?: string; to?: string }>;
}) {
  await requirePermission('accounting.ledgers.view');
  const params = await searchParams;
  const { from, to } = monthRange(params.from, params.to);
  const supplierId = params.supplier ?? '';

  const [suppliers, ledger] = await Promise.all([
    getLedgerSupplierOptions(),
    supplierId ? getSupplierLedger({ supplierId, from, to }) : Promise.resolve(null),
  ]);

  return (
    <>
      <PageHeader
        title="Supplier ledger"
        description="A supplier's running account, derived from party-tagged journal lines so it always agrees with Supplier Payables (spec §41)."
        count={ledger?.lines.length}
      />

      <PartyLedgerView
        basePath="/accounting/supplier-ledger"
        paramName="supplier"
        ledger={ledger}
        options={suppliers}
        selectedId={supplierId}
        from={from}
        to={to}
        labels={SUPPLIER_LEDGER_LABELS}
        detailHref={(l) => `/masters/suppliers/${l.partyId}/edit`}
      />
    </>
  );
}
