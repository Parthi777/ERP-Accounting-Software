import type { Metadata } from 'next';

import { requirePermission } from '@/server/auth/tenant-context';
import { PageHeader } from '@/components/data-table/data-table';
import { BankAccountForm } from '@/components/bank/bank-account-form';

export const metadata: Metadata = { title: 'New bank account' };
export const dynamic = 'force-dynamic';

export default async function Page() {
  // The branches this user may actually reach, from the session — not
  // org-service's getBranches(), which is gated on admin.branches.view and so
  // would throw for the Accounts role that owns this screen.
  const context = await requirePermission('bank.accounts.manage');
  const branches = context.accessibleBranches;

  return (
    <div className="mx-auto max-w-3xl">
      <PageHeader
        title="New bank account"
        description="Every account the dealer banks through, so receipts, statements and reconciliation have somewhere to go (spec §38)."
      />
      <BankAccountForm branches={branches.map((b) => ({ id: b.id, name: b.name }))} />
    </div>
  );
}
