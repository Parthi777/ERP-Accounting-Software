import 'server-only';

import { requirePermission } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { recordAudit } from '@/server/services/audit/record-audit';
import { fromDb, toDb, type Paise } from '@/lib/money';
import { getSetting } from '@/server/services/org/org-service';

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

  // With approval switched on (0081) the entry waits for a second person, and
  // is numbered only when it posts — a rejection leaves no gap in the series.
  if (await getSetting('approvals.manual_journal')) {
    const { error: requestError } = await supabase.rpc('request_manual_journal', {
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
      p_branch_id: input.branchId ?? context.activeBranch?.id ?? undefined,
      p_idempotency_key: input.idempotencyKey,
    });
    if (requestError) {
      return { ok: false, error: describeJournalError(requestError.message) };
    }
    return {
      ok: true,
      message: 'Submitted for approval. It posts when someone else approves it (Accounting → Approvals).',
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

  const [{ data, error }, { data: cashLedgers }, { data: bankLedgers }] = await Promise.all([
    supabase
      .from('chart_of_accounts')
      .select('id, code, name, account_type, is_group, status')
      // A group account is a heading, not somewhere a balance can sit.
      .eq('is_group', false)
      .eq('status', 'ACTIVE')
      .order('code'),
    supabase.from('cash_accounts').select('ledger_account_id'),
    supabase.from('bank_accounts').select('ledger_account_id'),
  ]);

  if (error) {
    throw new Error(`Failed to load the chart of accounts: ${error.message}`);
  }

  // Cash and bank are written through Bank/Cash entry and Contra, which move
  // the book with the ledger. A hand-written line would move only the ledger.
  const moneyLedgers = new Set(
    [...(cashLedgers ?? []), ...(bankLedgers ?? [])].map((c) => c.ledger_account_id),
  );

  return (data ?? []).filter((a) => !moneyLedgers.has(a.id)).map((a) => ({
    id: a.id,
    code: a.code,
    name: a.name,
    type: a.account_type,
  }));
}

/**
 * Who a journal line can be held against (0087): customers, suppliers and
 * finance companies of this dealer. The database refuses any other party.
 */
export async function getJournalParties(options: { readonly customers?: boolean } = {}): Promise<
  readonly { type: 'CUSTOMER' | 'SUPPLIER' | 'FINANCE_COMPANY'; id: string; label: string }[]
> {
  await requirePermission('accounting.journals.view');
  const supabase = await createSupabaseServerClient();
  const [finance, suppliers, customers] = await Promise.all([
    supabase.from('finance_companies').select('id, code, name').eq('status', 'ACTIVE').order('name'),
    supabase.from('suppliers').select('id, supplier_code, name').order('name').limit(2000),
    options.customers === false
      ? Promise.resolve({ data: [] as { id: string; customer_code: string; name: string; mobile: string | null }[] })
      : supabase.from('customers').select('id, customer_code, name, mobile').order('name').limit(3000),
  ]);
  return [
    ...(finance.data ?? []).map((f) => ({ type: 'FINANCE_COMPANY' as const, id: f.id, label: `${f.name} (${f.code})` })),
    ...(suppliers.data ?? []).map((x) => ({ type: 'SUPPLIER' as const, id: x.id, label: `${x.name} (${x.supplier_code})` })),
    ...(customers.data ?? []).map((c) => ({
      type: 'CUSTOMER' as const, id: c.id,
      label: `${c.name} (${c.customer_code}${c.mobile ? ` · ${c.mobile}` : ''})`,
    })),
  ];
}

/**
 * A posted entry's lines, to start its replacement from (0088). Correcting a
 * journal is reverse-then-repost (spec §23); this is the "repost" half's
 * starting point, so the accountant edits what was there instead of retyping.
 */
export async function getJournalForCorrection(id: string): Promise<{
  readonly entryNumber: string;
  readonly narration: string;
  readonly lines: readonly { accountId: string; debit: number; credit: number; narration: string | null; party: string }[];
} | null> {
  await requirePermission('accounting.journals.post');
  const supabase = await createSupabaseServerClient();
  const [{ data: entry }, { data: lines }] = await Promise.all([
    supabase.from('journal_entries').select('entry_number, narration').eq('id', id).maybeSingle(),
    supabase.from('journal_entry_lines').select('account_id, debit, credit, narration, party_type, party_id, line_number')
      .eq('journal_entry_id', id).order('line_number'),
  ]);
  if (!entry) return null;
  return {
    entryNumber: entry.entry_number,
    narration: entry.narration ?? '',
    lines: (lines ?? []).map((l) => ({
      accountId: l.account_id,
      debit: Number(l.debit),
      credit: Number(l.credit),
      narration: l.narration,
      party: l.party_type && l.party_id ? `${l.party_type}:${l.party_id}` : '',
    })),
  };
}

/** The account a customer's balance sits on: the invoice rule's receivable. */
export async function getReceivableAccountId(): Promise<string | null> {
  await requirePermission('accounting.journals.view');
  const supabase = await createSupabaseServerClient();
  const { data } = await supabase.from('accounting_rules').select('account_id')
    .eq('module', 'SALES').eq('event', 'INVOICE').eq('component', 'RECEIVABLE').eq('status', 'ACTIVE')
    .is('branch_id', null).limit(1).maybeSingle();
  return data?.account_id ?? null;
}

function describeJournalError(message: string): string {
  // The database names the line and the account for these, which is already
  // the message an operator needs; rewording it would lose the line number.
  if (
    message.startsWith('Journal line') ||
    message.startsWith('The books are locked') ||
    message.startsWith('A journal entry cannot be dated in the future')
  ) {
    return message;
  }
  if (message.includes('does not balance') || message.includes('must balance')) {
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

// ─────────────────────────────────────────────────────────────────────────────
// The ledger of one account — spec §41, §43
// ─────────────────────────────────────────────────────────────────────────────

export interface AccountLedgerLine {
  readonly journalEntryId: string;
  readonly entryDate: string;
  readonly entryNumber: string;
  readonly sourceModule: string;
  readonly status: string;
  readonly narration: string | null;
  /** What sat on the other side of the entry. */
  readonly contra: string | null;
  readonly debit: Paise;
  readonly credit: Paise;
  readonly runningBalance: Paise;
}

export interface AccountLedger {
  readonly account: { id: string; code: string; name: string; type: string } | null;
  readonly opening: Paise;
  readonly debit: Paise;
  readonly credit: Paise;
  readonly closing: Paise;
  readonly lines: readonly AccountLedgerLine[];
}

/**
 * What moved through one account, with the contra account named.
 *
 * "Why is Bank Charges 4,150 this month" had no answer on any screen before
 * this: the trial balance gives the total and stops, and the chart of accounts
 * is a list of names. Spec §43 asks that every number be drillable to the
 * transaction, and for accounts that are not a party or a bank, none was.
 */
export async function getAccountLedger(params: {
  readonly accountId: string;
  readonly from: string;
  readonly to: string;
  readonly branchId?: string | null;
}): Promise<AccountLedger> {
  await requirePermission('accounting.ledgers.view');
  const supabase = await createSupabaseServerClient();

  const [{ data: account }, { data: opening }, { data: rows, error }] = await Promise.all([
    supabase
      .from('chart_of_accounts')
      .select('id, code, name, account_type')
      .eq('id', params.accountId)
      .maybeSingle(),
    supabase.rpc('account_ledger_opening', { p_account_id: params.accountId, p_as_on: params.from }),
    supabase.rpc('account_ledger', {
      p_account_id: params.accountId,
      p_from: params.from,
      p_to: params.to,
      p_branch_id: params.branchId ?? null,
    }),
  ]);

  if (error) {
    throw new Error(`Failed to load the account ledger: ${error.message}`);
  }

  const lines: AccountLedgerLine[] = (rows ?? []).map((r) => ({
    journalEntryId: r.journal_entry_id,
    entryDate: r.entry_date,
    entryNumber: r.entry_number,
    sourceModule: r.source_module,
    status: r.status,
    narration: r.narration,
    contra: r.contra,
    debit: fromDb(r.debit),
    credit: fromDb(r.credit),
    runningBalance: fromDb(r.running_balance),
  }));

  const openingBalance = fromDb(opening as never);
  const debit = lines.reduce((sum, l) => sum + l.debit, 0) as Paise;
  const credit = lines.reduce((sum, l) => sum + l.credit, 0) as Paise;

  return {
    account: account
      ? { id: account.id, code: account.code, name: account.name, type: account.account_type }
      : null,
    opening: openingBalance,
    debit,
    credit,
    // Taken from the last row rather than recomputed, so the summary and the
    // table can never disagree about where the account ended.
    closing: (lines.at(-1)?.runningBalance ?? openingBalance) as Paise,
    lines,
  };
}
