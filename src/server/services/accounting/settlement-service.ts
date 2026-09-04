import 'server-only';

import { requireTenantContext, type TenantContext } from '@/server/auth/tenant-context';
import { ForbiddenError } from '@/server/errors';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { recordAudit } from '@/server/services/audit/record-audit';
import { add, formatINR, fromDb, subtract, toRupees, ZERO, type Paise } from '@/lib/money';
import type { Permission } from '@/lib/permissions';

/**
 * Bill-wise settlement of a party ledger — spec §41.
 *
 * The step this exists for is a real one in a dealer's day. A cashier takes
 * money as it arrives and records it against the customer; the ledger is then
 * correct in total and silent on detail — it knows what the customer owes and
 * not which invoices are still unpaid. Accounts closes that gap by splitting
 * each receipt across the bills it settles.
 *
 * Nothing here posts, reverses or amends a journal (spec §23, §60.12). A split
 * is a statement about entries that already exist, which is why a wrong one
 * costs nothing but re-doing it and why no reported figure moves when it
 * changes. What it buys is the identity the page is built around:
 *
 *     unpaid bills − unapplied receipts = the ledger closing balance
 *
 * Because both sides are drawn from the same party-tagged journal lines the
 * ledger itself is drawn from, that holds by construction. When it does not,
 * something is wrong with the data rather than with the arithmetic, and
 * `tallies` below says so rather than hiding it.
 */

export type PartyType = 'CUSTOMER' | 'SUPPLIER';

/** One side of the account: a bill raised, or money received against it. */
export interface OpenItem {
  readonly lineId: string;
  readonly entryId: string;
  readonly date: string;
  readonly entryNumber: string;
  /** 'SALE', 'SERVICE_INVOICE', 'BOOKING', … or null for a plain journal. */
  readonly documentType: string | null;
  /** What the dealer calls this document — the invoice number where there is one. */
  readonly documentRef: string;
  readonly accountCode: string;
  readonly accountName: string;
  readonly particulars: string | null;
  readonly side: 'DEBIT' | 'CREDIT';
  readonly amount: Paise;
  readonly allocated: Paise;
  readonly outstanding: Paise;
  readonly ageDays: number;
}

/** A line of one payment's split, as already recorded. */
export interface SettlementLink {
  readonly debitLineId: string;
  readonly amount: Paise;
}

export interface PartySettlement {
  readonly partyType: PartyType;
  readonly partyId: string;
  /** Bills with something still owing, oldest first. */
  readonly openBills: readonly OpenItem[];
  /** Payments with something still unapplied, oldest first. */
  readonly openPayments: readonly OpenItem[];
  /**
   * Payments already fully split, most recent first and capped. Present so a
   * split can be revised: a receipt that vanished the moment it was allocated
   * could never be corrected.
   */
  readonly settledPayments: readonly OpenItem[];
  /**
   * Bills that are fully settled but are named by one of the payments above.
   * Without them a split could be read but not edited — the bill it settles
   * would have no row to show an amount against.
   */
  readonly settledBills: readonly OpenItem[];
  /** True when older fully-split payments exist beyond the ones listed. */
  readonly historyTruncated: boolean;
  /** Existing splits, keyed by the payment's journal line id. */
  readonly splits: Readonly<Record<string, readonly SettlementLink[]>>;
  readonly totalOpenBills: Paise;
  readonly totalUnapplied: Paise;
  /** The account's balance from the ledger itself, all dates. */
  readonly ledgerClosing: Paise;
  /** Whether the two agree. They must; see the note above. */
  readonly tallies: boolean;
  /** Whether this session may change a split, as opposed to reading one. */
  readonly canSettle: boolean;
}

export interface SettlementResult {
  readonly ok: boolean;
  readonly error?: string;
  readonly message?: string;
}

/** How much settled history to carry to the client. */
const HISTORY_LIMIT = 25;

/**
 * Reached from Accounting for either party. `requirePermission` is all-of, which
 * is the wrong shape when a supplier ledger may also be opened by someone who
 * holds only the supplier master permission.
 */
async function requireEither(...permissions: readonly Permission[]): Promise<TenantContext> {
  const context = await requireTenantContext();
  if (!permissions.some((permission) => context.permissions.has(permission))) {
    throw new ForbiddenError(permissions[0]!);
  }
  return context;
}

const VIEW_PERMISSIONS: Readonly<Record<PartyType, readonly Permission[]>> = {
  CUSTOMER: ['accounting.ledgers.view', 'customers.view_ledger'],
  SUPPLIER: ['accounting.ledgers.view', 'masters.suppliers.view'],
};

/** PostgREST's answer when a function or table named here does not exist yet. */
function isMissingMigration(error: { code?: string; message: string }): boolean {
  return (
    error.code === 'PGRST202' ||
    error.code === '42883' ||
    error.code === '42P01' ||
    /Could not find the (function|table)/i.test(error.message)
  );
}

function toOpenItem(row: {
  line_id: string;
  entry_id: string;
  entry_date: string;
  entry_number: string;
  document_type: string | null;
  document_ref: string;
  account_code: string;
  account_name: string;
  particulars: string | null;
  side: string;
  amount: string;
  allocated: string;
  outstanding: string;
  age_days: number;
}): OpenItem {
  return {
    lineId: row.line_id,
    entryId: row.entry_id,
    date: row.entry_date,
    entryNumber: row.entry_number,
    documentType: row.document_type,
    documentRef: row.document_ref,
    accountCode: row.account_code,
    accountName: row.account_name,
    particulars: row.particulars,
    side: row.side === 'DEBIT' ? 'DEBIT' : 'CREDIT',
    amount: fromDb(row.amount),
    allocated: fromDb(row.allocated),
    outstanding: fromDb(row.outstanding),
    ageDays: row.age_days,
  };
}

/**
 * Everything the settlement panel needs for one party.
 *
 * Settled items are fetched alongside open ones rather than behind a second
 * round trip, because the totals have to be computed over the whole account
 * either way — a bill counts as settled only relative to every payment ever
 * made, not to the ones still on screen.
 */
export async function getPartySettlement(params: {
  readonly partyType: PartyType;
  readonly partyId: string;
}): Promise<PartySettlement | null> {
  const context = await requireEither(...VIEW_PERMISSIONS[params.partyType]);
  const supabase = await createSupabaseServerClient();

  const [items, closing, allocations] = await Promise.all([
    supabase.rpc('party_open_items', {
      p_party_type: params.partyType,
      p_party_id: params.partyId,
      p_include_settled: true,
    }),
    // The ledger's own answer, computed by the function the statement uses.
    // Deriving it from the rows above instead would make the tally check below
    // compare a number with itself and prove nothing.
    supabase.rpc('party_ledger_opening', {
      p_party_type: params.partyType,
      p_party_id: params.partyId,
      p_as_on: 'infinity',
    }),
    supabase
      .from('party_allocations')
      .select('credit_line_id, debit_line_id, amount')
      .eq('party_type', params.partyType)
      .eq('party_id', params.partyId),
  ]);

  // The application deploys to Railway on push while migrations are applied to
  // Supabase by hand, so there is a window in which this code is live and 0050
  // is not. Failing softly there costs the settlement panel and keeps the ledger
  // — failing hard would take a page accounts use every day off the air for a
  // schema change that has not happened yet. Only this one cause is forgiven;
  // any other error is a real fault and still raises.
  if (items.error) {
    if (isMissingMigration(items.error)) {
      console.warn('[settlement] migration 0050 has not been applied to this database');
      return null;
    }
    throw new Error(`Failed to load the open items: ${items.error.message}`);
  }
  if (closing.error) {
    throw new Error(`Failed to load the closing balance: ${closing.error.message}`);
  }
  if (allocations.error) {
    throw new Error(`Failed to load the existing settlements: ${allocations.error.message}`);
  }

  const rows = (items.data ?? []).map(toOpenItem);
  const open = rows.filter((row) => row.outstanding !== 0);
  const settled = rows.filter((row) => row.outstanding === 0);

  // Newest first for history — the split most likely to need revising is the one
  // just made — and oldest first for anything still awaiting attention, because
  // the oldest bill is the one that should be settled next.
  const byNewest = (a: OpenItem, b: OpenItem) => b.date.localeCompare(a.date);
  const allSettledPayments = settled.filter((row) => row.side === 'CREDIT').sort(byNewest);
  const settledPayments = allSettledPayments.slice(0, HISTORY_LIMIT);

  const splits: Record<string, SettlementLink[]> = {};
  for (const link of allocations.data ?? []) {
    (splits[link.credit_line_id] ??= []).push({
      debitLineId: link.debit_line_id,
      amount: fromDb(link.amount),
    });
  }

  const openBills = open.filter((row) => row.side === 'DEBIT');
  const openPayments = open.filter((row) => row.side === 'CREDIT');

  // A bill a listed payment already settled in full is gone from `openBills`,
  // but the editor still has to draw a row for it — otherwise the split that
  // closed it could be seen and never undone.
  const referenced = new Set(
    [...openPayments, ...settledPayments].flatMap((payment) =>
      (splits[payment.lineId] ?? []).map((link) => link.debitLineId),
    ),
  );
  const settledBills = settled.filter(
    (row) => row.side === 'DEBIT' && referenced.has(row.lineId),
  );
  const totalOpenBills = openBills.reduce((sum, row) => add(sum, row.outstanding), ZERO);
  const totalUnapplied = openPayments.reduce((sum, row) => add(sum, row.outstanding), ZERO);
  const ledgerClosing = fromDb((closing.data ?? 0) as string | number);

  return {
    partyType: params.partyType,
    partyId: params.partyId,
    openBills,
    openPayments,
    settledPayments,
    settledBills,
    historyTruncated: allSettledPayments.length > HISTORY_LIMIT,
    splits,
    totalOpenBills,
    totalUnapplied,
    ledgerClosing,
    tallies: subtract(totalOpenBills, totalUnapplied) === ledgerClosing,
    canSettle: context.permissions.has('accounting.allocations.manage'),
  };
}

export interface SplitInput {
  /** The journal line of the payment being split. */
  readonly creditLineId: string;
  /** The bills it settles. An empty list clears the split. */
  readonly allocations: readonly { readonly debitLineId: string; readonly amount: Paise }[];
  readonly note?: string | null;
}

/**
 * The database messages name journal entries because that is what the database
 * holds. These name what the accountant is looking at.
 */
function describeSettlementError(message: string): string {
  if (message.includes('left to settle')) {
    return 'One of these bills has already been settled by another payment. Reload the page and try again.';
  }
  if (message.includes('left to allocate')) {
    return 'The split adds up to more than this payment. Reduce it and try again.';
  }
  if (message.includes('same party')) {
    return 'A payment can only be set against the same party’s own bills.';
  }
  if (message.includes('not a payment')) {
    return 'Only money received can be split across bills.';
  }
  if (message.includes('not a bill')) {
    return 'A payment can only be set against a bill, not against another payment.';
  }
  if (message.includes('not attributed')) {
    return 'This entry is not attributed to a customer or supplier, so there is nothing to settle.';
  }
  if (message.includes('could not be found')) {
    return 'That payment could not be found. It may have been reversed since this page was loaded.';
  }
  return message;
}

/**
 * Records how one payment was split.
 *
 * The whole split is submitted, not a line of it, so re-submitting is harmless
 * (spec §50) and revising is one decision rather than a sequence of edits with
 * an inconsistent state in between.
 */
export async function splitPayment(input: SplitInput): Promise<SettlementResult> {
  const context = await requirePermissionToSettle();
  const supabase = await createSupabaseServerClient();

  if (!input.creditLineId) {
    return { ok: false, error: 'Choose the payment to split.' };
  }

  const lines = input.allocations.filter((line) => line.amount > 0);
  if (lines.some((line) => !line.debitLineId)) {
    return { ok: false, error: 'Every amount must name the bill it settles.' };
  }

  const total = lines.reduce((sum, line) => add(sum, line.amount), ZERO);

  const { data, error } = await supabase.rpc('allocate_party_payment', {
    p_credit_line_id: input.creditLineId,
    // Rupees, not paise: the function's parameter is numeric, which is what the
    // ledger stores. Converting at this boundary keeps the arithmetic above it
    // in integers (see src/lib/money.ts).
    p_allocations: lines.map((line) => ({
      debit_line_id: line.debitLineId,
      amount: toRupees(line.amount),
    })),
    p_note: input.note?.trim() || null,
  });

  if (error) {
    console.error('[settlement] split failed', error.message);
    return { ok: false, error: describeSettlementError(error.message) };
  }

  const row = Array.isArray(data) ? data[0] : data;
  const unapplied = fromDb(row?.unapplied ?? 0);

  await recordAudit({
    action: 'UPDATE',
    entityType: 'party_allocations',
    entityId: input.creditLineId,
    dealerId: context.dealerId,
    branchId: context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
    newData: {
      credit_line_id: input.creditLineId,
      bills: lines.length,
      allocated: toRupees(total),
      note: input.note ?? null,
    },
  });

  if (lines.length === 0) {
    return { ok: true, message: 'The split was cleared. The payment is unapplied again.' };
  }

  return {
    ok: true,
    message:
      unapplied === 0
        ? `Split across ${lines.length} bill${lines.length === 1 ? '' : 's'}. Nothing is left on account.`
        : `Split across ${lines.length} bill${lines.length === 1 ? '' : 's'}. ${formatINR(unapplied)} remains on account.`,
  };
}

async function requirePermissionToSettle(): Promise<TenantContext> {
  const context = await requireTenantContext();
  if (!context.permissions.has('accounting.allocations.manage')) {
    throw new ForbiddenError('accounting.allocations.manage');
  }
  return context;
}
