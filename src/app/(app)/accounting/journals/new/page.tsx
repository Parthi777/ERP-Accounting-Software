import type { Metadata } from 'next';
import Link from 'next/link';
import { ArrowLeft } from 'lucide-react';

import { requirePermission } from '@/server/auth/tenant-context';
import {
  getJournalForCorrection,
  getJournalParties,
  getPostableAccounts,
} from '@/server/services/accounting/journal-entry-service';
import { JournalEntryForm, type PartyOption } from '@/components/accounting/journal-entry-form';
import { PageHeader } from '@/components/data-table/data-table';
import { Button } from '@/components/ui/button';

export const metadata: Metadata = { title: 'New journal entry' };
export const dynamic = 'force-dynamic';

/**
 * A journal written by hand (spec §21). Reached three ways: plainly; from a
 * party's ledger (`?party=SUPPLIER:<id>`), with that party on the first line;
 * and as the second half of a correction (`?correct=<entry id>`), starting
 * from the lines of the entry that was just reversed.
 */
export default async function NewJournalPage({
  searchParams,
}: {
  searchParams: Promise<{ party?: string; correct?: string }>;
}) {
  await requirePermission('accounting.journals.post');
  const params = await searchParams;
  const [accounts, parties, correcting] = await Promise.all([
    getPostableAccounts(),
    getJournalParties(),
    params.correct ? getJournalForCorrection(params.correct) : Promise.resolve(null),
  ]);

  const [type, id] = (params.party ?? '').split(':');
  const defaultParty: PartyOption | undefined =
    type && id ? parties.find((p) => p.type === type && p.id === id) : undefined;

  return (
    <>
      <PageHeader
        title={correcting ? `Correct ${correcting.entryNumber}` : 'New journal entry'}
        description={
          correcting
            ? `${correcting.entryNumber} has been reversed. Edit the lines below and post the corrected entry; both stay on the record.`
            : "An entry written by hand — a bank charge, a depreciation entry, an accountant's correction (spec §21)."
        }
        action={
          <Button variant="secondary" size="sm" asChild>
            <Link href="/accounting/journals"><ArrowLeft aria-hidden />Journals</Link>
          </Button>
        }
      />

      <JournalEntryForm
        accounts={accounts}
        parties={parties}
        defaultParty={defaultParty}
        initialLines={correcting?.lines}
        defaultNarration={correcting ? `Correction of ${correcting.entryNumber}: ${correcting.narration}` : ''}
      />
    </>
  );
}
