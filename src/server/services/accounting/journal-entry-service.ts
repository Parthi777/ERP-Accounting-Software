import 'server-only';

import { requirePermission } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { recordAudit } from '@/server/services/audit/record-audit';
import { toDb, type Paise } from '@/lib/money';

/**
 * Journal entries a person writes, and the only sanctioned way to correct one —
 * spec §9, §21, §23.
 *
 * ── Why there is no edit ────────────────────────────────────────────────────
 *
 * A posted journal cannot be changed. The trigger in 0007 refuses it and says
 * why: "post a reversal and a corrected entry instead of editing". That is not
 * an implementation limit — an immutable ledger is what separates a book of
 * account from a spreadsheet, and every audit claim this product makes rests on
 * it.
 *
 * So correcting an entry is two documents, and both stay visible: a reversal
 * carrying its reason and author, then a replacement saying what should have
 * happened. Anyone reading the ledger later can see that a correction occurred,
 * which is the point of doing it this way rather than quietly rewriting a row.
 */

export interface JournalLineInput {
  readonly accountId: string;
  /** Exactly one of these is non-zero. In paise. */
  readonly debit: Paise;
  readonly credit: Paise;
  readonly narration?: string | null;
  readonly partyType?: 'CUSTOMER' | 'SUPPLIER' | 'FINANCE_COMPANY' | null;
  readonly partyId?: string | null;
}

export interface JournalResult {
  readonly ok: boolean;
  readonly id?: string;
  readonly entryNumber?: string;
  readonly message?: string;
  readonly error?: string;
}

/**
 * Posts an entry written by hand — a bank charge, a depreciation entry, an
 * accountant's correction.
 *
 * Balance is checked in the database, not here. A second copy of that rule in
 * TypeScript is a second place for it to drift, and the one in the database is
 * the one that actually holds.
 */
export async function postManualJournal(input: {
  readonly entryDate: string;
  readonly narration: string;
  readonly lines: readonly JournalLineInput[];
  readonly branchId?: string | null;
  readonly idempotencyKey: string;
}): Promise<JournalResult> {
  const context = await requirePermission('accounting.journals.post');
  const supabase = await createSupabaseServerClient();

  const usable = input.lines.filter((l) => l.debit > 0 || l.credit > 0);

  if (usable.length < 2) {
    return { ok: false, error: 'An entry needs at least two lines with an amount.' };
  }
  if (usable.some((l) => l.debit > 0 && l.credit > 0)) {
    return { ok: false, error: 'A line is either a debit or a credit, not both.' };
  }
  if (!input.narration.trim()) {
    return { ok: false, error: 'Say what this entry is for.' };
  }

  // Checked here as well as in the database — not for safety, but so the
  // operator sees the difference rather than a constraint message.
  const debits = usable.reduce((sum, l) => sum + l.debit, 0);
  const credits = usable.reduce((sum, l) => sum + l.credit, 0);
  if (debits !== credits) {
    return {
      ok: false,
      error: `Debits and credits differ by ${Math.abs(debits - credits) / 100}. An entry must balance.`,
    };
  }

  const { data, error } = await supabase.rpc('post_manual_journal', {
    p_entry_date: input.entryDate,
    p_narration: input.narration.trim(),
    p_lines: usable.map((l) => ({
      account_id: l.accountId,
      debit: Number(toDb(l.debit)),
      credit: Number(toDb(l.credit)),
      narration: l.narration?.trim() || null,
      party_type: l.partyType ?? null,
      party_id: l.partyId ?? null,
    })) as never,
    p_branch_id: input.branchId ?? context.activeBranch?.id ?? null,
    p_idempotency_key: input.idempotencyKey,
  });

  if (error) {
    console.error('[journal] manual post failed', error.message);
    return { ok: false, error: describeJournalError(error.message) };
  }

  const row = Array.isArray(data) ? data[0] : data;

  await recordAudit({
    action: 'POST',
    entityType: 'journal_entries',
    entityId: String(row?.journal_entry_id ?? ''),
    dealerId: context.dealerId,
    branchId: context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
    newData: { entryNumber: row?.entry_number, narration: input.narration, lines: usable.length },
  });

  return {
    ok: true,
    id: String(row?.journal_entry_id ?? ''),
    entryNumber: row?.entry_number ?? undefined,
    message: `Journal ${row?.entry_number} posted.`,
  };
}

/**
 * Reverses a posted journal — the correction mechanism spec §23 requires.
 *
 * The original stays exactly as it was and is marked REVERSED, linked to the
 * entry that undid it. Nothing is removed, because an entry that vanishes takes
 * the evidence of the mistake with it.
 */
export async function reverseJournal(input: {
  readonly journalId: string;
  readonly reason: string;
  readonly date?: string;
}): Promise<JournalResult> {
  const context = await requirePermission('accounting.journals.reverse');
  const supabase = await createSupabaseServerClient();

  if (!input.reason.trim()) {
    return { ok: false, error: 'A reversal must say why. The reason stays on the record.' };
  }

  const { data, error } = await supabase.rpc('reverse_journal_entry', {
    p_journal_entry_id: input.journalId,
    p_reason: input.reason.trim(),
    p_reversal_date: input.date ?? new Date().toISOString().slice(0, 10),
  });

  if (error) {
    console.error('[journal] reversal failed', error.message);
    return { ok: false, error: describeJournalError(error.message) };
  }

  const row = Array.isArray(data) ? data[0] : data;

  await recordAudit({
    action: 'REVERSE',
    entityType: 'journal_entries',
    entityId: input.journalId,
    dealerId: context.dealerId,
    branchId: context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
    newData: { reversalEntry: row?.entry_number, reason: input.reason },
  });

  return {
    ok: true,
    id: String(row?.journal_entry_id ?? ''),
    entryNumber: row?.entry_number ?? undefined,
    message: `Reversed by ${row?.entry_number}. Post a corrected entry next.`,
  };
}

/** The accounts a line can name, for the picker. */
export async function getPostableAccounts(): Promise<
  readonly { id: string; code: string; name: string; type: string }[]
> {
  await requirePermission('accounting.journals.view');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase
    .from('chart_of_accounts')
    .select('id, code, name, account_type, is_group, status')
    // A group account is a heading, not somewhere a balance can sit.
    .eq('is_group', false)
    .eq('status', 'ACTIVE')
    .order('code');

  if (error) {
    throw new Error(`Failed to load the chart of accounts: ${error.message}`);
  }

  return (data ?? []).map((a) => ({
    id: a.id,
    code: a.code,
    name: a.name,
    type: a.account_type,
  }));
}

function describeJournalError(message: string): string {
  if (message.includes('must balance') || message.includes('debit') && message.includes('credit')) {
    return 'The entry does not balance. Total debits must equal total credits (spec §22).';
  }
  if (message.includes('does not belong to this dealer')) {
    return 'One of the accounts is not in your chart of accounts.';
  }
  if (message.includes('POSTED') && message.includes('immutable')) {
    return 'That entry is posted and cannot be changed. Reverse it and post a corrected one.';
  }
  if (message.includes('is REVERSED')) {
    return 'That entry has already been reversed.';
  }
  if (message.includes('accounting period') || message.includes('closed')) {
    return 'That date falls in a closed accounting period.';
  }
  return message;
}
