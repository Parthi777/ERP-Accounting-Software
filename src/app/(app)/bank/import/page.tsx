import type { Metadata } from 'next';
import Link from 'next/link';
import { ArrowLeft } from 'lucide-react';

import { getBankAccounts } from '@/server/services/bank/bank-service';
import { requirePermission } from '@/server/auth/tenant-context';
import { PageHeader } from '@/components/data-table/data-table';
import { StatementImport } from '@/components/bank/statement-import';
import { Button } from '@/components/ui/button';

export const metadata: Metadata = { title: 'Import statement' };
export const dynamic = 'force-dynamic';

export default async function Page() {
  await requirePermission('bank.statement.import');
  const accounts = await getBankAccounts();

  return (
    <>
      <PageHeader
        title="Import bank statement"
        description="Staged for matching — importing a statement does not post anything to the ledger (spec §39)."
        action={
          <Button variant="secondary" size="sm" asChild>
            <Link href="/bank"><ArrowLeft aria-hidden />Accounts</Link>
          </Button>
        }
      />

      <StatementImport
        accounts={accounts.map((a) => ({ id: a.id, label: `${a.name} · ${a.accountNumber}` }))}
      />
    </>
  );
}
