import type { Metadata } from 'next';
import Link from 'next/link';
import { ArrowLeft } from 'lucide-react';

import { requirePermission } from '@/server/auth/tenant-context';
import { getPostableAccounts } from '@/server/services/accounting/journal-entry-service';
import { JournalEntryForm } from '@/components/accounting/journal-entry-form';
import { PageHeader } from '@/components/data-table/data-table';
import { Button } from '@/components/ui/button';

export const metadata: Metadata = { title: 'New journal entry' };
export const dynamic = 'force-dynamic';

export default async function NewJournalPage() {
  await requirePermission('accounting.journals.post');
  const accounts = await getPostableAccounts();

  return (
    <>
      <PageHeader
        title="New journal entry"
        description="An entry written by hand — a bank charge, a depreciation entry, an accountant's correction (spec §21)."
        action={
          <Button variant="secondary" size="sm" asChild>
            <Link href="/accounting/journals"><ArrowLeft aria-hidden />Journals</Link>
          </Button>
        }
      />

      <JournalEntryForm accounts={accounts} />
    </>
  );
}
