import type { Metadata } from 'next';

import {
  getFinanceCompanyLedger,
  getLedgerFinanceCompanyOptions,
} from '@/server/services/accounting/ledger-service';
import { requirePermission } from '@/server/auth/tenant-context';
import { PageHeader } from '@/components/data-table/data-table';
import { PartyLedgerView, FINANCE_LEDGER_LABELS } from '@/components/accounting/party-ledger-view';
import { rangeInYear } from '@/lib/period';

export const metadata: Metadata = { title: 'Finance company ledger' };
export const dynamic = 'force-dynamic';

/**
 * One finance company's account (spec §25): each loan booked against it from a
 * customer, each DD received, what it deducted. The accountant tallies it here
 * and posts a journal against it.
 */
export default async function FinanceLedgerPage({
  searchParams,
}: {
  searchParams: Promise<{ company?: string; from?: string; to?: string }>;
}) {
  const context = await requirePermission('finance.companies.view');
  const params = await searchParams;
  const { from, to } = rangeInYear(context.activeFinancialYear, params.from, params.to);
  const companyId = params.company ?? '';
  const canPost = context.permissions.has('accounting.journals.post');
  const canOpen = context.permissions.has('accounting.journals.view');

  const [companies, ledger] = await Promise.all([
    getLedgerFinanceCompanyOptions(),
    companyId ? getFinanceCompanyLedger({ companyId, from, to }) : Promise.resolve(null),
  ]);

  return (
    <>
      <PageHeader
        title="Finance company ledger"
        description="Loans booked against the financier, DDs received and what they kept back — one company at a time."
        count={ledger?.lines.length}
      />
      <PartyLedgerView
        basePath="/finance/ledger"
        paramName="company"
        ledger={ledger}
        options={companies}
        selectedId={companyId}
        from={from}
        to={to}
        labels={FINANCE_LEDGER_LABELS}
        detailHref={(l) => `/finance/companies/${l.partyId}/edit`}
        journalHref={canPost ? (l) => `/accounting/journals/new?party=FINANCE_COMPANY:${l.partyId}` : null}
        linkEntries={canOpen}
      />
    </>
  );
}
