import 'server-only';

import { requirePermission } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { recordAudit } from '@/server/services/audit/record-audit';
import { parseCsv } from '@/lib/csv';

/**
 * Opening balance import — spec §24, §41, §44.
 *
 * The last thing standing between a dealer's old system and this one. Masters
 * can be imported and stock counted, but until the party balances are on the
 * books the customer ledger, the supplier ledger and every ageing report
 * describe a business that began on the cut-over date.
 *
 * `customer_ledger_opening` (0037) has always been able to *compute* an opening
 * from journals. Entering one meant typing a journal line per party by hand,
 * which for a few hundred parties is a week's work and a certain transposition
 * error.
 *
 * ── The sign convention ─────────────────────────────────────────────────────
 *
 * One `amount` column, signed. Positive means the party owes the dealer;
 * negative means the dealer owes the party. A file with separate debit and
 * credit columns invites a row carrying both, and then someone has to decide
 * what that means.
 *
 * It reads the same for either party type: +5000 against a customer is a debtor,
 * +5000 against a supplier is an advance the dealer has already paid out.
 */

export interface OpeningBalanceRow {
  readonly rowNumber: number;
  readonly party_code: string;
  readonly party_name: string;
  readonly amount: string;
  readonly direction: string;
  readonly errors: readonly string[];
}

export interface OpeningBalancePreview {
  readonly rows: readonly OpeningBalanceRow[];
  readonly validCount: number;
  readonly errorCount: number;
  readonly headers: readonly string[];
  /** Net debit across the file — what will land in 3300. */
  readonly net: number;
}

export interface OpeningBalanceResult {
  readonly ok: boolean;
  readonly imported?: number;
  readonly error?: string;
}

export type PartyType = 'CUSTOMER' | 'SUPPLIER';

const KNOWN_HEADERS = ['party_code', 'amount'] as const;

function fileError(message: string, headers: string[] = []): OpeningBalancePreview {
  return {
    rows: [{ rowNumber: 0, party_code: '', party_name: '', amount: '', direction: '', errors: [message] }],
    validCount: 0,
    errorCount: 1,
    headers,
    net: 0,
  };
}

export async function previewOpeningBalances(
  partyType: PartyType,
  csv: string,
): Promise<OpeningBalancePreview> {
  await requirePermission('accounting.journals.post');
  const supabase = await createSupabaseServerClient();

  const { headers, rows: raw } = parseCsv(csv);

  if (raw.length === 0) {
    return fileError('The file has a header row but no data rows.', headers);
  }

  const missing = KNOWN_HEADERS.filter((h) => !headers.includes(h));
  if (missing.length > 0) {
    return fileError(`The file is missing required columns: ${missing.join(', ')}.`, headers);
  }

  // Every party code this dealer has, so an unknown one is named in the preview
  // rather than failing the post. RLS scopes the read.
  const { data, error } =
    partyType === 'CUSTOMER'
      ? await supabase.from('customers').select('customer_code, name')
      : await supabase.from('suppliers').select('supplier_code, name');

  if (error) {
    throw new Error(`Failed to read the party list: ${error.message}`);
  }

  const known = new Map<string, string>();
  for (const row of data ?? []) {
    const code = 'customer_code' in row ? row.customer_code : row.supplier_code;
    known.set(code, row.name);
  }

  const seen = new Map<string, number>();
  let net = 0;

  const rows: OpeningBalanceRow[] = raw.map((cells, index) => {
    const rowNumber = index + 2;
    const code = (cells['party_code'] ?? '').trim();
    const rawAmount = (cells['amount'] ?? '').trim().replace(/,/g, '');
    const errors: string[] = [];

    if (!code) errors.push('party_code: required.');
    else if (!known.has(code)) {
      errors.push(
        `party_code: no ${partyType.toLowerCase()} with code ${code}. Import the master first.`,
      );
    } else {
      const first = seen.get(code);
      if (first) {
        errors.push(
          `party_code: repeated in this file (also row ${first}). ` +
            `Combine them into one balance — two lines would both post.`,
        );
      } else {
        seen.set(code, rowNumber);
      }
    }

    const amount = Number(rawAmount);
    if (!rawAmount) errors.push('amount: required.');
    else if (!Number.isFinite(amount)) errors.push(`amount: "${rawAmount}" is not a number.`);
    else if (amount === 0) errors.push('amount: zero is not an opening balance — omit the row.');

    if (errors.length === 0) net += amount;

    return {
      rowNumber,
      party_code: code,
      party_name: known.get(code) ?? '—',
      amount: Number.isFinite(amount) ? amount.toFixed(2) : rawAmount,
      direction:
        !Number.isFinite(amount) || amount === 0
          ? '—'
          : amount > 0
            ? 'Owes the dealer'
            : 'Dealer owes',
      errors,
    };
  });

  const errorCount = rows.filter((r) => r.errors.length > 0).length;
  return { rows, validCount: rows.length - errorCount, errorCount, headers, net };
}

export async function commitOpeningBalances(
  partyType: PartyType,
  csv: string,
  asOn: string,
  idempotencyKey: string,
): Promise<OpeningBalanceResult> {
  const context = await requirePermission('accounting.journals.post');

  const preview = await previewOpeningBalances(partyType, csv);

  if (preview.errorCount > 0) {
    return {
      ok: false,
      error:
        `${preview.errorCount} row(s) still have errors. Fix them and upload again — ` +
        `nothing has been posted.`,
    };
  }

  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase.rpc('post_opening_balances', {
    p_party_type: partyType,
    p_rows: preview.rows.map((r) => ({ party_code: r.party_code, amount: Number(r.amount) })),
    p_as_on: asOn,
    p_narration: null,
    p_idempotency_key: idempotencyKey,
  });

  if (error) {
    console.error('[opening] post failed', error.code, error.message);
    return { ok: false, error: `${error.message} Nothing was posted.` };
  }

  const row = Array.isArray(data) ? data[0] : data;
  const parties = Number(row?.parties ?? 0);

  await recordAudit({
    action: 'IMPORT',
    entityType: 'journal_entries',
    entityId: String(row?.journal_entry_id ?? ''),
    dealerId: context.dealerId,
    branchId: context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
    newData: { partyType, parties, asOn, journal: row?.journal_entry_id },
  });

  return { ok: true, imported: parties };
}

export function openingBalanceTemplate(partyType: PartyType): string {
  const example =
    partyType === 'CUSTOMER'
      ? 'CUST-000001,12500.00\nCUST-000002,-3000.00\n'
      : 'SUPP-000001,-8000.00\nSUPP-000002,2500.00\n';
  return `party_code,amount\n${example}`;
}

// ─────────────────────────────────────────────────────────────────────────────
// Bill-wise opening balances (0091)
// ─────────────────────────────────────────────────────────────────────────────
//
// The same cut-over, one row per unpaid bill instead of one per party: its
// number, bill date, due date and the amount still open, always positive —
// whether it is owed to or by the dealer follows from the ledger chosen. Each
// bill is then settled and aged on its own.

export interface OpeningBillRow {
  readonly rowNumber: number;
  readonly party_code: string;
  readonly party_name: string;
  readonly bill_reference: string;
  readonly bill_date: string;
  readonly due_date: string;
  readonly amount: string;
  readonly errors: readonly string[];
}

export interface OpeningBillPreview {
  readonly rows: readonly OpeningBillRow[];
  readonly validCount: number;
  readonly errorCount: number;
  readonly headers: readonly string[];
  readonly total: number;
}

const BILL_HEADERS = ['party_code', 'bill_reference', 'bill_date', 'amount'] as const;
const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;

function billFileError(message: string, headers: string[] = []): OpeningBillPreview {
  return {
    rows: [{ rowNumber: 0, party_code: '', party_name: '', bill_reference: '', bill_date: '', due_date: '', amount: '', errors: [message] }],
    validCount: 0,
    errorCount: 1,
    headers,
    total: 0,
  };
}

export async function previewOpeningBills(
  partyType: PartyType,
  csv: string,
  asOn: string,
): Promise<OpeningBillPreview> {
  await requirePermission('accounting.journals.post');
  const supabase = await createSupabaseServerClient();

  const { headers, rows: raw } = parseCsv(csv);
  if (raw.length === 0) return billFileError('The file has a header row but no data rows.', headers);
  const missing = BILL_HEADERS.filter((h) => !headers.includes(h));
  if (missing.length > 0) return billFileError(`The file is missing required columns: ${missing.join(', ')}.`, headers);

  const [parties, existing] = await Promise.all([
    partyType === 'CUSTOMER'
      ? supabase.from('customers').select('id, customer_code, name')
      : supabase.from('suppliers').select('id, supplier_code, name'),
    supabase.from('opening_bills').select('party_id, bill_reference').eq('party_type', partyType),
  ]);
  if (parties.error) throw new Error(`Failed to read the party list: ${parties.error.message}`);

  const known = new Map<string, { id: string; name: string }>();
  for (const row of parties.data ?? []) {
    const code = 'customer_code' in row ? row.customer_code : row.supplier_code;
    known.set(code, { id: row.id, name: row.name });
  }
  const entered = new Set((existing.data ?? []).map((b) => `${b.party_id}|${b.bill_reference}`));
  const seen = new Map<string, number>();
  let total = 0;

  const rows: OpeningBillRow[] = raw.map((cells, index) => {
    const rowNumber = index + 2;
    const code = (cells['party_code'] ?? '').trim();
    const ref = (cells['bill_reference'] ?? '').trim();
    const billDate = (cells['bill_date'] ?? '').trim();
    const dueDate = (cells['due_date'] ?? '').trim();
    const rawAmount = (cells['amount'] ?? '').trim().replace(/,/g, '');
    const party = known.get(code);
    const errors: string[] = [];

    if (!code) errors.push('party_code: required.');
    else if (!party) errors.push(`party_code: no ${partyType.toLowerCase()} with code ${code}. Import the master first.`);
    if (!ref) errors.push('bill_reference: required.');
    if (party && ref) {
      const key = `${party.id}|${ref}`;
      if (entered.has(key)) errors.push(`bill_reference: ${ref} is already entered for this party.`);
      const first = seen.get(key);
      if (first) errors.push(`bill_reference: repeated in this file (also row ${first}).`);
      else seen.set(key, rowNumber);
    }
    if (!ISO_DATE.test(billDate)) errors.push('bill_date: use YYYY-MM-DD.');
    else if (billDate > asOn) errors.push(`bill_date: after the as-at date ${asOn}.`);
    if (dueDate && !ISO_DATE.test(dueDate)) errors.push('due_date: use YYYY-MM-DD, or leave it empty.');
    else if (dueDate && ISO_DATE.test(billDate) && dueDate < billDate) errors.push('due_date: before the bill date.');
    const amount = Number(rawAmount);
    if (!rawAmount) errors.push('amount: required.');
    else if (!Number.isFinite(amount) || amount <= 0) errors.push('amount: the open amount, above zero.');

    if (errors.length === 0) total += amount;
    return {
      rowNumber,
      party_code: code,
      party_name: party?.name ?? '—',
      bill_reference: ref,
      bill_date: billDate,
      due_date: dueDate,
      amount: Number.isFinite(amount) ? amount.toFixed(2) : rawAmount,
      errors,
    };
  });

  const errorCount = rows.filter((r) => r.errors.length > 0).length;
  return { rows, validCount: rows.length - errorCount, errorCount, headers, total };
}

export async function commitOpeningBills(
  partyType: PartyType,
  csv: string,
  asOn: string,
  idempotencyKey: string,
): Promise<OpeningBalanceResult> {
  const context = await requirePermission('accounting.journals.post');
  const preview = await previewOpeningBills(partyType, csv, asOn);
  if (preview.errorCount > 0) {
    return { ok: false, error: `${preview.errorCount} row(s) still have errors. Fix them and upload again — nothing has been posted.` };
  }

  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.rpc('post_opening_bills', {
    p_party_type: partyType,
    p_rows: preview.rows.map((r) => ({
      party_code: r.party_code,
      bill_reference: r.bill_reference,
      bill_date: r.bill_date,
      due_date: r.due_date || null,
      amount: Number(r.amount),
    })),
    p_as_on: asOn,
    p_idempotency_key: idempotencyKey,
  });
  if (error) {
    console.error('[opening] bill-wise post failed', error.code, error.message);
    return { ok: false, error: `${error.message} Nothing was posted.` };
  }

  const row = Array.isArray(data) ? data[0] : data;
  const bills = Number(row?.bills ?? 0);
  await recordAudit({
    action: 'IMPORT',
    entityType: 'journal_entries',
    entityId: String(row?.journal_entry_id ?? ''),
    dealerId: context.dealerId,
    branchId: context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
    newData: { partyType, bills, asOn, billWise: true, journal: row?.journal_entry_id },
  });
  return { ok: true, imported: bills };
}

export function openingBillTemplate(partyType: PartyType): string {
  const example =
    partyType === 'CUSTOMER'
      ? 'CUST-000001,INV-1042,2026-02-10,2026-03-12,12500.00\nCUST-000001,INV-1107,2026-03-05,,4000.00\n'
      : 'SUPP-000001,TVS/88121,2026-01-20,2026-02-19,80000.00\nSUPP-000001,TVS/88342,2026-03-02,2026-04-01,20000.00\n';
  return `party_code,bill_reference,bill_date,due_date,amount\n${example}`;
}
