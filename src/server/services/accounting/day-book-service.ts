import 'server-only';

import { requirePermission } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';

/**
 * The day book (0091, BUSY F32): every voucher posted on a day, with its
 * lines, and each branch's cash position for that day from the cash book.
 */

export interface DayBookLine {
  readonly lineNumber: number;
  readonly accountCode: string;
  readonly accountName: string;
  readonly partyName: string | null;
  readonly narration: string | null;
  readonly debit: number;
  readonly credit: number;
}

export interface DayBookVoucher {
  readonly entryId: string;
  readonly entryNumber: string;
  readonly time: string;
  readonly documentType: string | null;
  readonly documentRef: string;
  readonly narration: string | null;
  readonly status: string;
  readonly branchName: string | null;
  readonly lines: DayBookLine[];
}

export interface CashPosition {
  readonly branchName: string;
  readonly status: string;
  readonly opening: number;
  readonly receipts: number;
  readonly payments: number;
  readonly closing: number;
}

export async function getDayBook(date: string, branchId: string | null): Promise<{
  vouchers: DayBookVoucher[];
  cash: CashPosition[];
}> {
  await requirePermission('accounting.journals.view');
  const supabase = await createSupabaseServerClient();

  let cashQuery = supabase
    .from('cash_day_closings')
    .select('status, opening_balance, total_receipts, total_payments, expected_closing, branches ( name )')
    .eq('business_date', date);
  if (branchId) cashQuery = cashQuery.eq('branch_id', branchId);

  const [book, cash] = await Promise.all([
    supabase.rpc('day_book', { p_date: date, p_branch_id: branchId ?? undefined }),
    cashQuery,
  ]);
  if (book.error) throw new Error(`Failed to load the day book: ${book.error.message}`);

  const vouchers: DayBookVoucher[] = [];
  const byId = new Map<string, DayBookVoucher>();
  for (const r of book.data ?? []) {
    let v = byId.get(r.entry_id);
    if (!v) {
      v = {
        entryId: r.entry_id,
        entryNumber: r.entry_number,
        time: r.entry_time,
        documentType: r.document_type,
        documentRef: r.document_ref,
        narration: r.narration,
        status: r.status,
        branchName: r.branch_name,
        lines: [],
      };
      byId.set(r.entry_id, v);
      vouchers.push(v);
    }
    v.lines.push({
      lineNumber: r.line_number,
      accountCode: r.account_code,
      accountName: r.account_name,
      partyName: r.party_name,
      narration: r.line_narration,
      debit: Number(r.debit ?? 0),
      credit: Number(r.credit ?? 0),
    });
  }

  return {
    vouchers,
    cash: (cash.data ?? []).map((c) => ({
      branchName: c.branches?.name ?? '—',
      status: c.status,
      opening: Number(c.opening_balance ?? 0),
      receipts: Number(c.total_receipts ?? 0),
      payments: Number(c.total_payments ?? 0),
      closing: Number(c.expected_closing ?? 0),
    })),
  };
}
