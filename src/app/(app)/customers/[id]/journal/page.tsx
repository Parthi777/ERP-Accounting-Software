import type { Metadata } from 'next';
import Link from 'next/link';
import { notFound } from 'next/navigation';
import { ArrowLeft } from 'lucide-react';

import { getCustomer } from '@/server/services/customers/customer-service';
import { getCustomerLedger } from '@/server/services/accounting/ledger-service';
import {
  getJournalParties,
  getPostableAccounts,
  getReceivableAccountId,
} from '@/server/services/accounting/journal-entry-service';
import { getFinanceApplications, getFinancePickers } from '@/server/services/finance/finance-service';
import { hasPermission, requirePermission } from '@/server/auth/tenant-context';
import { NotFoundError } from '@/server/errors';
import { JournalEntryForm } from '@/components/accounting/journal-entry-form';
import { ApplicationActions } from '@/components/finance/application-actions';
import { PageHeader } from '@/components/data-table/data-table';
import { Panel, PanelContent, PanelHeader, PanelTitle, SolidPanel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { formatINR, paise, toRupees } from '@/lib/money';

const ZERO = paise(0);
import { formatDate } from '@/lib/format';
import { rangeInYear } from '@/lib/period';

export const metadata: Metadata = { title: 'Customer journal' };
export const dynamic = 'force-dynamic';

/**
 * Tallying one customer's account — the accountant's screen after a sale.
 *
 * The customer's running ledger (debit, credit, balance) sits beside a journal
 * form that already names the customer on the receivable line, so an
 * adjustment lands on their statement and not only on the control account.
 * A financed sale is cleared here too: the finance company's DD is received
 * with whatever it kept back (document charges, freight), each charged to the
 * customer or to the dealer.
 */
export default async function CustomerJournalPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const context = await requirePermission('accounting.journals.post');

  let customer;
  try {
    customer = await getCustomer(id);
  } catch (error) {
    if (error instanceof NotFoundError) notFound();
    throw error;
  }

  const { from, to } = rangeInYear(context.activeFinancialYear);
  const canFinance = hasPermission(context, 'finance.applications.view');
  const canManageFinance = hasPermission(context, 'finance.applications.manage');

  const [ledger, accounts, parties, receivable, applications, pickers] = await Promise.all([
    getCustomerLedger({ customerId: customer.id, from, to }),
    getPostableAccounts(),
    getJournalParties({ customers: false }),
    getReceivableAccountId(),
    canFinance ? getFinanceApplications({ status: 'ALL', branchId: null, q: customer.customer_code }) : Promise.resolve([]),
    canManageFinance ? getFinancePickers() : Promise.resolve({ companies: [], bankAccounts: [] }),
  ]);
  const financeRows = applications.filter((a) => a.customerId === customer.id);
  const th = 'px-3 py-2 text-[11px] font-semibold uppercase tracking-wide text-ink-500';
  const closing = ledger?.closing ?? ZERO;

  return (
    <div className="space-y-5">
      <Button variant="ghost" size="sm" asChild className="-ml-2">
        <Link href={`/customers/${customer.id}`}><ArrowLeft aria-hidden />{customer.name}</Link>
      </Button>

      <PageHeader
        title={`Journal — ${customer.name}`}
        description={`${customer.customer_code} · Tally the customer's account: every line below names them, so it reaches their ledger.`}
      />

      <div className="grid gap-3 sm:grid-cols-3">
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Debits this year</p>
          <p className="numeric mt-1 text-lg font-semibold text-ink-900">{formatINR(ledger?.totalDebit ?? ZERO)}</p>
        </Panel>
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Credits this year</p>
          <p className="numeric mt-1 text-lg font-semibold text-ink-900">{formatINR(ledger?.totalCredit ?? ZERO)}</p>
        </Panel>
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Balance</p>
          <p className={`numeric mt-1 text-lg font-semibold ${closing === 0 ? 'text-positive-700' : closing > 0 ? 'text-warning-700' : 'text-brand-700'}`}>
            {formatINR(closing)} {closing > 0 ? 'Dr — customer owes' : closing < 0 ? 'Cr — held for customer' : '— tallied'}
          </p>
        </Panel>
      </div>

      {financeRows.length > 0 && (
        <SolidPanel className="overflow-hidden">
          <div className="border-b border-ink-100 px-4 py-3">
            <h2 className="text-sm font-semibold text-ink-900">Finance</h2>
            <p className="text-xs text-ink-500">
              Receive the financier&rsquo;s DD here. Enter what they kept back — document charges, freight — and
              choose whether the customer pays it or it is the dealer&rsquo;s cost.
            </p>
          </div>
          <table className="w-full border-collapse text-sm">
            <thead><tr>
              <th className={`${th} text-left`}>Application</th><th className={`${th} text-left`}>Financier</th>
              <th className={`${th} text-right`}>Loan</th><th className={`${th} text-right`}>Received</th>
              <th className={`${th} text-right`}>Pending</th><th className={th} />
            </tr></thead>
            <tbody>
              {financeRows.map((a) => (
                <tr key={a.id} className="border-t border-ink-100">
                  <td className="px-3 py-2">
                    <span className="font-mono text-xs">{a.applicationNumber}</span>
                    <span className="ml-2"><Badge variant={a.disbursementStatus === 'DISBURSED' ? 'positive' : 'neutral'}>
                      {a.approvalStatus === 'APPROVED' ? a.disbursementStatus : a.approvalStatus}
                    </Badge></span>
                    {a.ddNumber && <span className="block text-[11px] text-ink-400">DD {a.ddNumber}</span>}
                  </td>
                  <td className="px-3 py-2">{a.companyName}</td>
                  <td className="numeric px-3 py-2">{formatINR(a.approvedAmount ?? a.loanAmount)}</td>
                  <td className="numeric px-3 py-2">{formatINR(a.disbursedAmount)}</td>
                  <td className="numeric px-3 py-2 font-medium">{formatINR(a.pendingAmount)}</td>
                  <td className="px-3 py-2">
                    <ApplicationActions
                      applicationId={a.id}
                      applicationNumber={a.applicationNumber}
                      approvalStatus={a.approvalStatus}
                      disbursementStatus={a.disbursementStatus}
                      pendingAmount={toRupees(a.pendingAmount)}
                      bankAccounts={pickers.bankAccounts}
                      canManage={canManageFinance}
                    />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </SolidPanel>
      )}

      <Panel>
        <PanelHeader><PanelTitle>New journal entry</PanelTitle></PanelHeader>
        <PanelContent>
          <p className="mb-3 text-xs text-ink-500">
            The first line is this customer&rsquo;s receivable. Debit it to charge them (e.g. document or freight
            charges: Cr Other Income), credit it to reduce what they owe (a discount allowed: Dr the sales
            account). A line can also name a finance company or supplier.
          </p>
          <JournalEntryForm
            accounts={accounts}
            defaultAccountId={receivable ?? undefined}
            parties={parties}
            defaultParty={{ type: 'CUSTOMER', id: customer.id, label: `${customer.name} (${customer.customer_code})` }}
            afterPost="stay"
          />
        </PanelContent>
      </Panel>

      <SolidPanel className="overflow-hidden">
        <div className="flex items-center justify-between border-b border-ink-100 px-4 py-3">
          <h2 className="text-sm font-semibold text-ink-900">Ledger {formatDate(from)} – {formatDate(to)}</h2>
          <Link href={`/customers/ledger?customer=${customer.id}`} className="text-xs text-brand-700 hover:underline">
            Full statement →
          </Link>
        </div>
        <div className="table-sticky overflow-auto" style={{ maxHeight: '32rem' }}>
          <table className="w-full border-collapse text-sm">
            <thead><tr>
              <th className={`${th} text-left`}>Date</th><th className={`${th} text-left`}>Entry</th>
              <th className={`${th} text-left`}>Particulars</th><th className={`${th} text-right`}>Debit</th>
              <th className={`${th} text-right`}>Credit</th><th className={`${th} text-right`}>Balance</th>
            </tr></thead>
            <tbody>
              <tr className="border-t border-ink-100 bg-ink-50/60">
                <td className="px-3 py-2 text-ink-500" colSpan={5}>Opening balance</td>
                <td className="numeric px-3 py-2 font-medium">{formatINR(ledger?.opening ?? ZERO)}</td>
              </tr>
              {(ledger?.lines ?? []).map((l, i) => (
                <tr key={`${l.entryNumber}-${i}`} className="border-t border-ink-100">
                  <td className="px-3 py-2 text-ink-600">{formatDate(l.date)}</td>
                  <td className="px-3 py-2 font-mono text-xs">{l.entryNumber}</td>
                  <td className="px-3 py-2 text-ink-700">{l.narration ?? ''}</td>
                  <td className="numeric px-3 py-2">{l.debit ? formatINR(l.debit) : ''}</td>
                  <td className="numeric px-3 py-2">{l.credit ? formatINR(l.credit) : ''}</td>
                  <td className="numeric px-3 py-2 font-medium">{formatINR(l.balance)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </SolidPanel>
    </div>
  );
}
