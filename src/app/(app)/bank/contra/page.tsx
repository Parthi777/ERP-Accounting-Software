import type { Metadata } from 'next';
import Link from 'next/link';
import { ArrowLeft } from 'lucide-react';

import { getBankAccounts } from '@/server/services/bank/bank-service';
import { requirePermission } from '@/server/auth/tenant-context';
import { PageHeader } from '@/components/data-table/data-table';
import { ContraForm, type MoneyAccountOption } from '@/components/bank/contra-form';
import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';

export const metadata: Metadata = { title: 'Contra' };
export const dynamic = 'force-dynamic';

/**
 * Contra voucher — spec §36, §38.
 *
 * Money moving between two of the dealer's own accounts. Neither a receipt nor a
 * payment, so it has its own screen: a receipt or payment writes one book, and
 * a transfer written as one leaves the other book disagreeing with the ledger.
 */
export default async function ContraPage() {
  const context = await requirePermission('bank.book.record');
  const accounts = await getBankAccounts();

  const options: MoneyAccountOption[] = [
    ...context.accessibleBranches.map((b) => ({ value: `CASH:${b.id}`, label: `Cash — ${b.name}` })),
    ...accounts
      .filter((a) => a.status === 'ACTIVE')
      .map((a) => ({ value: `BANK:${a.id}`, label: `${a.name} · ${a.accountNumber}` })),
  ];

  return (
    <>
      <PageHeader
        title="Contra"
        description="Cash deposited, cash withdrawn, or money moved between banks. Both books move, and nothing is booked as income or expense."
        action={
          <Button variant="secondary" size="sm" asChild>
            <Link href="/bank"><ArrowLeft aria-hidden />Accounts</Link>
          </Button>
        }
      />

      {accounts.length === 0 ? (
        <Panel className="p-6">
          <p className="text-sm text-ink-700">
            Add a bank account first — a contra always has a bank on at least one side.
          </p>
        </Panel>
      ) : (
        <ContraForm options={options} />
      )}
    </>
  );
}
