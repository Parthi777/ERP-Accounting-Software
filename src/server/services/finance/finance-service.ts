import 'server-only';

import { requirePermission, type TenantContext } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { add, fromDb, subtract, ZERO, type Paise } from '@/lib/money';
import { recordAudit } from '@/server/services/audit/record-audit';
import { BANK_BACKED_TYPES, type TradeAdvanceType } from '@/lib/finance/trade-advance';

/**
 * Finance — spec §25, §26, §27.
 *
 * Three screens share this file because they share one subject: the dealer's
 * position with each finance company. An HP application becomes a receivable
 * when it disburses; a trade advance moves that position directly; a settlement
 * clears it. Splitting them across three services would put the same balance in
 * three places.
 *
 * Every write goes through a single database function, so the journal, the bank
 * book and the finance ledger are written together or not at all.
 *
 * Commission is restricted (spec §52). It is dropped here, at the service
 * boundary, rather than hidden in the table — a role without
 * `finance.commission.view` never receives the number.
 */

export type ApprovalStatus = 'PENDING' | 'APPROVED' | 'REJECTED' | 'CANCELLED';
export type SettlementStatus = 'DRAFT' | 'POSTED' | 'CANCELLED';

export interface FinanceResult {
  readonly ok: boolean;
  readonly error?: string;
  readonly message?: string;
  readonly id?: string;
  readonly number?: string;
}

export interface FinanceApplicationRow {
  readonly id: string;
  readonly applicationNumber: string;
  readonly applicationDate: string;
  readonly customerId: string;
  readonly customerName: string;
  readonly companyId: string;
  readonly companyName: string;
  readonly chassisNo: string | null;
  readonly branchName: string;
  readonly loanAmount: Paise;
  readonly downPayment: Paise;
  readonly approvedAmount: Paise | null;
  readonly disbursedAmount: Paise;
  readonly pendingAmount: Paise;
  readonly approvalStatus: ApprovalStatus;
  readonly disbursementStatus: string;
  readonly ddNumber: string | null;
  readonly bankReference: string | null;
  /** Null when the role may not see commission. */
  readonly commissionAmount: Paise | null;
}

export interface FinancePenetration {
  readonly applications: number;
  readonly approved: number;
  readonly pending: number;
  readonly rejected: number;
  readonly loanAmount: Paise;
  readonly disbursedAmount: Paise;
  readonly pendingAmount: Paise;
}

function resolveBranch(context: TenantContext, requested: string | null): string | null {
  if (!requested) {
    return context.hasAllBranchAccess ? null : (context.activeBranch?.id ?? null);
  }
  return context.accessibleBranches.some((b) => b.id === requested)
    ? requested
    : (context.activeBranch?.id ?? null);
}

export async function getFinanceApplications(params: {
  readonly status: string;
  readonly branchId: string | null;
  readonly q?: string;
  /**
   * Row cap. Defaults to the screen's, which is all anyone scrolls; the
   * report exporter raises it, because a spreadsheet has no such limit and a
   * silently truncated financial extract is worse than none.
   */
  readonly limit?: number;
}): Promise<FinanceApplicationRow[]> {
  const context = await requirePermission('finance.applications.view');
  const supabase = await createSupabaseServerClient();

  let query = supabase
    .from('finance_applications')
    .select(
      'id, application_number, application_date, loan_amount, down_payment, approved_amount, disbursed_amount, pending_amount, approval_status, disbursement_status, dd_number, bank_reference, commission_amount, customer_id, finance_company_id, customers!inner ( name ), finance_companies!inner ( name ), branches!inner ( name ), vehicles ( chassis_no )',
    )
    .order('application_date', { ascending: false })
    .limit(params.limit ?? 200);

  if (params.status !== 'ALL') {
    query = query.eq('approval_status', params.status as ApprovalStatus);
  }
  const branchId = resolveBranch(context, params.branchId);
  if (branchId) {
    query = query.eq('branch_id', branchId);
  }

  const { data, error } = await query;
  if (error) {
    throw new Error(`Failed to load finance applications: ${error.message}`);
  }

  const maySeeCommission = context.permissions.has('finance.commission.view');
  const term = params.q?.trim().toLowerCase();

  return (data ?? [])
    .map((row) => ({
      id: row.id,
      applicationNumber: row.application_number,
      applicationDate: row.application_date,
      customerId: row.customer_id,
      customerName: row.customers.name,
      companyId: row.finance_company_id,
      companyName: row.finance_companies.name,
      chassisNo: row.vehicles?.chassis_no ?? null,
      branchName: row.branches.name,
      loanAmount: fromDb(row.loan_amount),
      downPayment: fromDb(row.down_payment),
      approvedAmount: row.approved_amount === null ? null : fromDb(row.approved_amount),
      disbursedAmount: fromDb(row.disbursed_amount),
      pendingAmount: fromDb(row.pending_amount),
      approvalStatus: row.approval_status,
      disbursementStatus: row.disbursement_status,
      ddNumber: row.dd_number,
      bankReference: row.bank_reference,
      commissionAmount: maySeeCommission ? fromDb(row.commission_amount) : null,
    }))
    .filter(
      (row) =>
        !term ||
        row.applicationNumber.toLowerCase().includes(term) ||
        row.customerName.toLowerCase().includes(term) ||
        row.companyName.toLowerCase().includes(term) ||
        (row.chassisNo?.toLowerCase().includes(term) ?? false),
    );
}

/**
 * Finance penetration — spec §27. Derived from the same rows the table shows,
 * so the summary can never disagree with the list beneath it.
 */
export function summarise(rows: readonly FinanceApplicationRow[]): FinancePenetration {
  return rows.reduce<FinancePenetration>(
    (acc, row) => ({
      applications: acc.applications + 1,
      approved: acc.approved + (row.approvalStatus === 'APPROVED' ? 1 : 0),
      pending: acc.pending + (row.approvalStatus === 'PENDING' ? 1 : 0),
      rejected: acc.rejected + (row.approvalStatus === 'REJECTED' ? 1 : 0),
      loanAmount: add(acc.loanAmount, row.loanAmount),
      disbursedAmount: add(acc.disbursedAmount, row.disbursedAmount),
      pendingAmount: add(acc.pendingAmount, row.pendingAmount),
    }),
    {
      applications: 0, approved: 0, pending: 0, rejected: 0,
      loanAmount: ZERO, disbursedAmount: ZERO, pendingAmount: ZERO,
    },
  );
}

export interface CreateApplicationInput {
  readonly customerId: string;
  readonly financeCompanyId: string;
  readonly loanAmount: number;
  readonly downPayment?: number;
  readonly vehicleId?: string | null;
  readonly tenureMonths?: number | null;
  readonly interestRate?: number | null;
  readonly commissionAmount?: number;
  readonly notes?: string | null;
}

export async function createFinanceApplication(
  input: CreateApplicationInput,
): Promise<FinanceResult> {
  const context = await requirePermission('finance.applications.manage');
  const supabase = await createSupabaseServerClient();

  if (!context.activeBranch) {
    return { ok: false, error: 'Select a branch before raising an application.' };
  }
  if (!input.customerId) return { ok: false, error: 'Choose the customer.' };
  if (!input.financeCompanyId) return { ok: false, error: 'Choose the finance company.' };
  if (!(input.loanAmount > 0)) return { ok: false, error: 'Enter a loan amount greater than zero.' };

  const { data, error } = await supabase.rpc('create_finance_application', {
    p_branch_id: context.activeBranch.id,
    p_customer_id: input.customerId,
    p_finance_company_id: input.financeCompanyId,
    p_loan_amount: input.loanAmount,
    p_down_payment: input.downPayment ?? 0,
    p_vehicle_id: input.vehicleId || null,
    p_tenure_months: input.tenureMonths ?? null,
    p_interest_rate: input.interestRate ?? null,
    p_commission_amount: input.commissionAmount ?? 0,
    p_notes: input.notes?.trim() || null,
  });

  if (error) {
    console.error('[finance] application failed', error.message);
    return { ok: false, error: describeFinanceError(error.message) };
  }

  const row = Array.isArray(data) ? data[0] : data;

  await recordAudit({
    action: 'CREATE',
    entityType: 'finance_applications',
    entityId: row?.application_id ?? null,
    dealerId: context.dealerId,
    branchId: context.activeBranch.id,
    userId: context.userId,
    userEmail: context.email,
    newData: { application_number: row?.application_number, loan_amount: input.loanAmount },
  });

  return { ok: true, id: row?.application_id, number: row?.application_number };
}

export async function decideFinanceApplication(
  id: string,
  decision: 'APPROVED' | 'REJECTED' | 'CANCELLED',
  approvedAmount?: number,
  reason?: string,
): Promise<FinanceResult> {
  const context = await requirePermission('finance.applications.manage');
  const supabase = await createSupabaseServerClient();

  if (decision === 'APPROVED' && !(approvedAmount && approvedAmount > 0)) {
    return { ok: false, error: 'An approval must state the amount the company agreed to.' };
  }
  if (decision === 'REJECTED' && !reason?.trim()) {
    return { ok: false, error: 'A rejection must state a reason. It stays on the record.' };
  }

  const { error } = await supabase.rpc('decide_finance_application', {
    p_application_id: id,
    p_decision: decision,
    p_approved_amount: decision === 'APPROVED' ? (approvedAmount ?? null) : null,
    p_rejection_reason: reason?.trim() || null,
  });

  if (error) {
    console.error('[finance] decision failed', error.message);
    return { ok: false, error: describeFinanceError(error.message) };
  }

  await recordAudit({
    action: decision === 'APPROVED' ? 'APPROVE' : 'REJECT',
    entityType: 'finance_applications',
    entityId: id,
    dealerId: context.dealerId,
    branchId: context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
    newData: { approval_status: decision, approved_amount: approvedAmount ?? null },
    reason: reason?.trim() || undefined,
  });

  return { ok: true, id };
}

export async function disburseFinanceApplication(input: {
  readonly applicationId: string;
  readonly amount: number;
  readonly bankAccountId: string;
  readonly ddNumber?: string | null;
  readonly bankReference?: string | null;
}): Promise<FinanceResult> {
  const context = await requirePermission('finance.applications.manage');
  const supabase = await createSupabaseServerClient();

  if (!(input.amount > 0)) return { ok: false, error: 'Enter an amount greater than zero.' };
  if (!input.bankAccountId) return { ok: false, error: 'Choose the bank account the money reached.' };

  const { error } = await supabase.rpc('disburse_finance_application', {
    p_application_id: input.applicationId,
    p_amount: input.amount,
    p_bank_account_id: input.bankAccountId,
    p_dd_number: input.ddNumber?.trim() || null,
    p_bank_reference: input.bankReference?.trim() || null,
  });

  if (error) {
    console.error('[finance] disbursement failed', error.message);
    return { ok: false, error: describeFinanceError(error.message) };
  }

  await recordAudit({
    action: 'POST',
    entityType: 'finance_applications',
    entityId: input.applicationId,
    dealerId: context.dealerId,
    branchId: context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
    newData: { disbursed: input.amount, reference: input.bankReference },
  });

  return { ok: true, message: 'Recorded. The bank book and the company ledger both show it.' };
}

// ── Trade advances — spec §26 ────────────────────────────────────────────────

export { TRADE_ADVANCE_TYPES, BANK_BACKED_TYPES } from '@/lib/finance/trade-advance';
export type { TradeAdvanceType } from '@/lib/finance/trade-advance';

export interface FinanceCompanyBalance {
  readonly id: string;
  readonly code: string;
  readonly name: string;
  readonly balance: Paise;
}

export interface FinanceLedgerLine {
  readonly date: string;
  readonly type: string;
  readonly referenceNumber: string | null;
  readonly narration: string | null;
  readonly debit: Paise;
  readonly credit: Paise;
  readonly balance: Paise;
}

export interface FinanceCompanyLedger {
  readonly companyId: string;
  readonly companyName: string;
  readonly from: string;
  readonly to: string;
  readonly opening: Paise;
  readonly closing: Paise;
  readonly totalDebit: Paise;
  readonly totalCredit: Paise;
  readonly lines: readonly FinanceLedgerLine[];
}

/**
 * One balance per company, never a combined figure — spec §25 is explicit that
 * finance companies are not pooled.
 */
export async function getFinanceCompanyBalances(): Promise<readonly FinanceCompanyBalance[]> {
  await requirePermission('finance.trade_advance.view');
  const supabase = await createSupabaseServerClient();

  const [companies, movements] = await Promise.all([
    supabase.from('finance_companies').select('id, code, name').eq('status', 'ACTIVE').order('name'),
    supabase.from('finance_transactions').select('finance_company_id, debit, credit').limit(20000),
  ]);

  if (companies.error) throw new Error(`Failed to load companies: ${companies.error.message}`);
  if (movements.error) throw new Error(`Failed to load balances: ${movements.error.message}`);

  const balances = new Map<string, Paise>();
  for (const row of movements.data ?? []) {
    const current = balances.get(row.finance_company_id) ?? ZERO;
    balances.set(
      row.finance_company_id,
      subtract(add(current, fromDb(row.credit)), fromDb(row.debit)),
    );
  }

  return (companies.data ?? []).map((c) => ({
    id: c.id,
    code: c.code,
    name: c.name,
    balance: balances.get(c.id) ?? ZERO,
  }));
}

export async function getFinanceCompanyLedger(params: {
  readonly companyId: string;
  readonly from: string;
  readonly to: string;
}): Promise<FinanceCompanyLedger | null> {
  await requirePermission('finance.trade_advance.view');
  const supabase = await createSupabaseServerClient();

  const [company, ledger] = await Promise.all([
    supabase.from('finance_companies').select('id, name').eq('id', params.companyId).maybeSingle(),
    supabase.rpc('finance_company_ledger', {
      p_company_id: params.companyId,
      p_from: params.from,
      p_to: params.to,
    }),
  ]);

  if (company.error) throw new Error(`Failed to load the company: ${company.error.message}`);
  if (!company.data) return null;
  if (ledger.error) throw new Error(`Failed to load the ledger: ${ledger.error.message}`);

  const rows = ledger.data ?? [];
  // The RPC leads with a synthetic OPENING row, so the opening balance is read
  // rather than recomputed.
  const opening = rows.length > 0 ? fromDb(rows[0]!.balance_after) : ZERO;
  const lines: FinanceLedgerLine[] = rows
    .filter((row) => row.transaction_type !== 'OPENING')
    .map((row) => ({
      date: row.transaction_date,
      type: row.transaction_type,
      referenceNumber: row.reference_number,
      narration: row.narration,
      debit: fromDb(row.debit),
      credit: fromDb(row.credit),
      balance: fromDb(row.balance_after),
    }));

  return {
    companyId: company.data.id,
    companyName: company.data.name,
    from: params.from,
    to: params.to,
    opening,
    closing: lines.length > 0 ? lines[lines.length - 1]!.balance : opening,
    totalDebit: lines.reduce((sum, l) => add(sum, l.debit), ZERO),
    totalCredit: lines.reduce((sum, l) => add(sum, l.credit), ZERO),
    lines,
  };
}

export async function recordTradeAdvance(input: {
  readonly companyId: string;
  readonly type: TradeAdvanceType;
  readonly amount: number;
  readonly bankAccountId?: string | null;
  readonly date?: string;
  readonly narration?: string | null;
  readonly reference?: string | null;
}): Promise<FinanceResult> {
  const context = await requirePermission('finance.trade_advance.manage');
  const supabase = await createSupabaseServerClient();

  if (!context.activeBranch) {
    return { ok: false, error: 'Select a branch before recording a trade advance.' };
  }
  if (!input.companyId) return { ok: false, error: 'Choose the finance company.' };
  if (!(input.amount > 0)) return { ok: false, error: 'Enter an amount greater than zero.' };
  if (BANK_BACKED_TYPES.includes(input.type) && !input.bankAccountId) {
    return { ok: false, error: 'Choose the bank account the money moved through.' };
  }

  const { error } = await supabase.rpc('record_trade_advance', {
    p_finance_company_id: input.companyId,
    p_branch_id: context.activeBranch.id,
    p_type: input.type,
    p_amount: input.amount,
    p_bank_account_id: input.bankAccountId || null,
    p_date: input.date || undefined,
    p_narration: input.narration?.trim() || null,
    p_reference: input.reference?.trim() || null,
  });

  if (error) {
    console.error('[finance] trade advance failed', error.message);
    return { ok: false, error: describeFinanceError(error.message) };
  }

  await recordAudit({
    action: 'POST',
    entityType: 'finance_transactions',
    entityId: input.companyId,
    dealerId: context.dealerId,
    branchId: context.activeBranch.id,
    userId: context.userId,
    userEmail: context.email,
    newData: { type: input.type, amount: input.amount },
  });

  return { ok: true, message: 'Recorded against the company ledger.' };
}

// ── Settlements — spec §26 ───────────────────────────────────────────────────

export interface SettlementRow {
  readonly id: string;
  readonly settlementNumber: string;
  readonly settlementDate: string;
  readonly companyName: string;
  readonly fromDate: string | null;
  readonly toDate: string | null;
  readonly grossAmount: Paise;
  readonly commissionAmount: Paise | null;
  readonly deductions: Paise;
  readonly netAmount: Paise;
  readonly status: string;
  readonly journalEntryId: string | null;
}

export async function getFinanceSettlements(status: string, limit = 200): Promise<SettlementRow[]> {
  const context = await requirePermission('finance.settlements.manage');
  const supabase = await createSupabaseServerClient();

  let query = supabase
    .from('finance_settlements')
    .select(
      'id, settlement_number, settlement_date, from_date, to_date, gross_amount, commission_amount, deductions, net_amount, status, journal_entry_id, finance_companies!inner ( name )',
    )
    .order('settlement_date', { ascending: false })
    .limit(limit);

  if (status !== 'ALL') {
    query = query.eq('status', status as SettlementStatus);
  }

  const { data, error } = await query;
  if (error) throw new Error(`Failed to load settlements: ${error.message}`);

  const maySeeCommission = context.permissions.has('finance.commission.view');

  return (data ?? []).map((row) => ({
    id: row.id,
    settlementNumber: row.settlement_number,
    settlementDate: row.settlement_date,
    companyName: row.finance_companies.name,
    fromDate: row.from_date,
    toDate: row.to_date,
    grossAmount: fromDb(row.gross_amount),
    commissionAmount: maySeeCommission ? fromDb(row.commission_amount) : null,
    deductions: fromDb(row.deductions),
    netAmount: fromDb(row.net_amount),
    status: row.status,
    journalEntryId: row.journal_entry_id,
  }));
}

export async function createFinanceSettlement(input: {
  readonly companyId: string;
  readonly from: string;
  readonly to: string;
  readonly gross: number;
  readonly commission?: number;
  readonly deductions?: number;
  readonly notes?: string | null;
}): Promise<FinanceResult> {
  const context = await requirePermission('finance.settlements.manage');
  const supabase = await createSupabaseServerClient();

  if (!context.activeBranch) {
    return { ok: false, error: 'Select a branch before raising a settlement.' };
  }
  if (!input.companyId) return { ok: false, error: 'Choose the finance company.' };
  if (!(input.gross > 0)) return { ok: false, error: 'Enter a gross amount greater than zero.' };

  const { data, error } = await supabase.rpc('create_finance_settlement', {
    p_finance_company_id: input.companyId,
    p_branch_id: context.activeBranch.id,
    p_from: input.from,
    p_to: input.to,
    p_gross: input.gross,
    p_commission: input.commission ?? 0,
    p_deductions: input.deductions ?? 0,
    p_notes: input.notes?.trim() || null,
  });

  if (error) {
    console.error('[finance] settlement failed', error.message);
    return { ok: false, error: describeFinanceError(error.message) };
  }

  const row = Array.isArray(data) ? data[0] : data;

  await recordAudit({
    action: 'CREATE',
    entityType: 'finance_settlements',
    entityId: row?.settlement_id ?? null,
    dealerId: context.dealerId,
    branchId: context.activeBranch.id,
    userId: context.userId,
    userEmail: context.email,
    newData: { settlement_number: row?.settlement_number, gross: input.gross },
  });

  return { ok: true, id: row?.settlement_id, number: row?.settlement_number };
}

export async function postFinanceSettlement(
  id: string,
  bankAccountId: string,
): Promise<FinanceResult> {
  const context = await requirePermission('finance.settlements.manage');
  const supabase = await createSupabaseServerClient();

  if (!bankAccountId) {
    return { ok: false, error: 'Choose the bank account the settlement was paid into.' };
  }

  const { error } = await supabase.rpc('post_finance_settlement', {
    p_settlement_id: id,
    p_bank_account_id: bankAccountId,
  });

  if (error) {
    console.error('[finance] settlement posting failed', error.message);
    return { ok: false, error: describeFinanceError(error.message) };
  }

  await recordAudit({
    action: 'POST',
    entityType: 'finance_settlements',
    entityId: id,
    dealerId: context.dealerId,
    branchId: context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
  });

  return { ok: true, message: 'Posted. The receivable is cleared at gross.' };
}

// ── Pickers ──────────────────────────────────────────────────────────────────

export async function getFinancePickers(): Promise<{
  companies: readonly { id: string; label: string }[];
  bankAccounts: readonly { id: string; label: string }[];
}> {
  await requirePermission('finance.companies.view');
  const supabase = await createSupabaseServerClient();

  const [companies, banks] = await Promise.all([
    supabase.from('finance_companies').select('id, code, name').eq('status', 'ACTIVE').order('name'),
    supabase.from('bank_accounts').select('id, name, account_number').eq('status', 'ACTIVE').order('name'),
  ]);

  if (companies.error) throw new Error(`Failed to load companies: ${companies.error.message}`);
  if (banks.error) throw new Error(`Failed to load bank accounts: ${banks.error.message}`);

  return {
    companies: (companies.data ?? []).map((c) => ({ id: c.id, label: `${c.code} · ${c.name}` })),
    bankAccounts: (banks.data ?? []).map((b) => ({
      id: b.id,
      label: `${b.name} · ${b.account_number}`,
    })),
  };
}

function describeFinanceError(message: string): string {
  if (message.includes('No accounting rule')) {
    return 'Accounting rules for finance are not fully configured. Nothing was posted.';
  }
  if (message.includes('period covering')) {
    return 'The accounting period for that date is closed.';
  }
  if (message.includes('only an approved application')) {
    return 'Only an approved application can be disbursed.';
  }
  if (message.includes('is still to be disbursed')) {
    return message;
  }
  if (message.includes('is already')) {
    return message;
  }
  if (message.includes('needs the bank account')) {
    return message;
  }
  if (message.includes('cannot exceed the gross')) {
    return 'Commission and deductions together cannot exceed the gross amount.';
  }
  if (message.includes('cannot be posted again')) {
    return 'This settlement has already been posted.';
  }
  return `The finance entry could not be recorded: ${message}`;
}
