import type { Metadata } from 'next';
import { notFound } from 'next/navigation';

import { requirePermission } from '@/server/auth/tenant-context';
import { getBankAccount } from '@/server/services/bank/bank-service';
import { PageHeader } from '@/components/data-table/data-table';
import { BankAccountForm } from '@/components/bank/bank-account-form';

export const metadata: Metadata = { title: 'Edit bank account' };
export const dynamic = 'force-dynamic';

export default async function Page({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const context = await requirePermission('bank.accounts.manage');
  const account = await getBankAccount(id);

  if (!account) {
    notFound();
  }

  return (
    <div className="mx-auto max-w-3xl">
      <PageHeader title={account.name} description="Bank account details." />
      <BankAccountForm
        branches={context.accessibleBranches.map((b) => ({ id: b.id, name: b.name }))}
        account={{
          id: account.id,
          name: account.name,
          bankName: account.bank_name,
          accountNumber: account.account_number,
          ifsc: account.ifsc,
          accountType: account.account_type,
          status: account.status,
          branchId: account.branch_id,
          openingBalance: String(account.opening_balance),
        }}
      />
    </div>
  );
}
