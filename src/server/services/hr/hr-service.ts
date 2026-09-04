import 'server-only';

import { requirePermission, requireTenantContext, type TenantContext } from '@/server/auth/tenant-context';
import { ForbiddenError } from '@/server/errors';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { recordAudit } from '@/server/services/audit/record-audit';
import { fromDb, type Paise } from '@/lib/money';

/**
 * HR — spec §12, §15, §46, §47, §52.
 *
 * The employee record the rest of HR stands on. Attendance measures a day
 * against a shift and a leave type; payroll computes from a salary structure
 * and a leave balance. None of those existed, so both were unbuildable.
 *
 * Two rules shape this layer:
 *
 *   Pay is effective-dated, never edited. A revision is a new row and the old
 *   one keeps its figures, so a payslip re-run for March reproduces March
 *   (spec §15) — the same reason an invoice keeps the price it was raised at.
 *
 *   Pay is confidential. It has its own permission, its own RLS policy, and its
 *   own entry in the redaction map, because spec §52 wants a restricted field
 *   absent from the response rather than merely hidden by the UI.
 */

export type EmploymentType = 'PERMANENT' | 'PROBATION' | 'CONTRACT' | 'INTERN' | 'CONSULTANT';
export type EmployeeStatus = 'ACTIVE' | 'ON_LEAVE' | 'RESIGNED' | 'TERMINATED';

export interface Shift {
  readonly id: string;
  readonly code: string;
  readonly name: string;
  readonly startsAt: string;
  readonly endsAt: string;
  readonly breakMinutes: number;
  readonly graceMinutes: number;
  readonly weekOffDays: readonly number[];
  readonly halfDayMinutes: number;
  readonly fullDayMinutes: number;
  readonly status: string;
}

export interface LeaveType {
  readonly id: string;
  readonly code: string;
  readonly name: string;
  readonly annualQuota: number;
  readonly isPaid: boolean;
  readonly carryForward: boolean;
  readonly maxCarryForward: number;
  readonly countsAsWorked: boolean;
  readonly status: string;
}

export interface SalaryStructure {
  readonly id: string;
  readonly effectiveFrom: string;
  readonly effectiveTo: string | null;
  readonly basic: Paise;
  readonly hra: Paise;
  readonly conveyance: Paise;
  readonly medicalAllowance: Paise;
  readonly specialAllowance: Paise;
  readonly otherAllowance: Paise;
  readonly pfEmployee: Paise;
  readonly esiEmployee: Paise;
  readonly professionalTax: Paise;
  readonly otherDeduction: Paise;
  readonly pfEmployer: Paise;
  readonly esiEmployer: Paise;
  readonly grossEarnings: Paise;
  readonly totalDeductions: Paise;
  readonly netPayable: Paise;
  readonly costToCompany: Paise;
  readonly revisionNote: string | null;
  /** True for the structure in force today. */
  readonly current: boolean;
}

export interface LeaveBalance {
  readonly id: string;
  readonly leaveTypeId: string;
  readonly leaveTypeCode: string;
  readonly leaveTypeName: string;
  readonly financialYear: string;
  readonly opening: number;
  readonly accrued: number;
  readonly used: number;
  readonly encashed: number;
  readonly balance: number;
}

export interface EmployeeDocument {
  readonly id: string;
  readonly documentType: string;
  readonly documentName: string;
  readonly documentNo: string | null;
  readonly issuedOn: string | null;
  readonly expiresOn: string | null;
  readonly storagePath: string | null;
  readonly notes: string | null;
  /** Days until expiry; negative when already lapsed, null when it never expires. */
  readonly expiresInDays: number | null;
}

export interface EmployeeListRow {
  readonly id: string;
  readonly employeeCode: string;
  readonly name: string;
  readonly department: string | null;
  readonly designation: string | null;
  readonly mobile: string | null;
  readonly branchName: string;
  readonly shiftName: string | null;
  readonly employmentType: EmploymentType;
  readonly joiningDate: string | null;
  readonly status: EmployeeStatus;
}

export interface EmployeeRecord extends EmployeeListRow {
  readonly branchId: string;
  readonly email: string | null;
  readonly personalEmail: string | null;
  readonly dateOfBirth: string | null;
  readonly gender: string | null;
  readonly bloodGroup: string | null;
  readonly emergencyContact: string | null;
  readonly emergencyMobile: string | null;
  readonly addressLine1: string | null;
  readonly addressLine2: string | null;
  readonly city: string | null;
  readonly state: string | null;
  readonly pincode: string | null;
  readonly pan: string | null;
  readonly aadhaarLast4: string | null;
  readonly uan: string | null;
  readonly esiNumber: string | null;
  readonly bankAccountName: string | null;
  readonly bankAccountNo: string | null;
  readonly bankIfsc: string | null;
  readonly probationUntil: string | null;
  readonly confirmedOn: string | null;
  readonly leavingDate: string | null;
  readonly exitType: string | null;
  readonly exitReason: string | null;
  readonly reportsToName: string | null;
  readonly shiftId: string | null;
  /** Empty when this session may not see pay (spec §52). */
  readonly salaryHistory: readonly SalaryStructure[];
  readonly canSeeSalary: boolean;
  readonly canManageSalary: boolean;
  readonly leaveBalances: readonly LeaveBalance[];
  readonly documents: readonly EmployeeDocument[];
}

export interface HrResult {
  readonly ok: boolean;
  readonly id?: string;
  readonly error?: string;
  readonly message?: string;
}

function describeHrError(message: string): string {
  if (message.includes('ess_net_check')) {
    return 'The deductions come to more than the earnings. Check the figures — nobody works for a negative wage.';
  }
  if (message.includes('A later salary structure already exists')) {
    return 'There is already a revision dated after this one. A structure is added after the last, never back-dated over it.';
  }
  if (message.includes('ess_employee_from_key')) {
    return 'A salary structure already starts on that date. Choose another effective date, or revise the existing one.';
  }
  if (message.includes('employees_exit_shape_check')) {
    return 'Someone marked as resigned or terminated has to say how they left.';
  }
  if (message.includes('employees_pan_check')) {
    return 'That PAN is not in the right format (five letters, four digits, one letter).';
  }
  if (message.includes('employees_ifsc_check')) {
    return 'That IFSC is not in the right format.';
  }
  if (message.includes('shifts_dealer_code_key')) {
    return 'A shift with that code already exists.';
  }
  if (message.includes('leave_types_dealer_code_key')) {
    return 'A leave type with that code already exists.';
  }
  if (message.includes('leave_types_carry_check')) {
    return 'Leave that does not carry forward cannot have a carry-forward cap.';
  }
  if (message.includes('elb_employee_type_year_key')) {
    return 'That employee already has a balance for this leave type and year. Adjust it rather than adding another.';
  }
  if (message.includes('shifts_minutes_check')) {
    return 'A full day has to be longer than a half day.';
  }
  return message;
}

/** Days from today until a date; negative once it has passed. */
function daysUntil(date: string | null): number | null {
  if (!date) return null;
  const then = Date.parse(`${date}T00:00:00Z`);
  const now = Date.parse(`${new Date().toISOString().slice(0, 10)}T00:00:00Z`);
  return Math.round((then - now) / 86_400_000);
}

export async function getShifts(): Promise<Shift[]> {
  await requirePermission('masters.employees.view');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase
    .from('shifts')
    .select('id, code, name, starts_at, ends_at, break_minutes, grace_minutes, week_off_days, half_day_minutes, full_day_minutes, status')
    .order('code');

  if (error) throw new Error(`Failed to load shifts: ${error.message}`);

  return (data ?? []).map((row) => ({
    id: row.id,
    code: row.code,
    name: row.name,
    startsAt: row.starts_at,
    endsAt: row.ends_at,
    breakMinutes: row.break_minutes,
    graceMinutes: row.grace_minutes,
    weekOffDays: (row.week_off_days ?? []).map(Number),
    halfDayMinutes: row.half_day_minutes,
    fullDayMinutes: row.full_day_minutes,
    status: row.status,
  }));
}

export async function getLeaveTypes(): Promise<LeaveType[]> {
  await requirePermission('masters.employees.view');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase
    .from('leave_types')
    .select('id, code, name, annual_quota, is_paid, carry_forward, max_carry_forward, counts_as_worked, status')
    .order('code');

  if (error) throw new Error(`Failed to load leave types: ${error.message}`);

  return (data ?? []).map((row) => ({
    id: row.id,
    code: row.code,
    name: row.name,
    annualQuota: Number(row.annual_quota),
    isPaid: row.is_paid,
    carryForward: row.carry_forward,
    maxCarryForward: Number(row.max_carry_forward),
    countsAsWorked: row.counts_as_worked,
    status: row.status,
  }));
}

export async function getEmployees(params: {
  readonly q?: string;
  readonly status?: string;
}): Promise<EmployeeListRow[]> {
  const context = await requirePermission('masters.employees.view');
  const supabase = await createSupabaseServerClient();

  let query = supabase
    .from('employees')
    .select('id, employee_code, name, department, designation, mobile, employment_type, joining_date, status, branch_id, shift_id, branches!inner ( name )')
    .order('employee_code')
    .limit(500);

  if (params.status && params.status !== 'ALL') {
    query = query.eq('status', params.status as EmployeeStatus);
  }
  if (!context.hasAllBranchAccess && context.activeBranch) {
    query = query.eq('branch_id', context.activeBranch.id);
  }

  const { data, error } = await query;
  if (error) throw new Error(`Failed to load employees: ${error.message}`);

  const shifts = await getShifts();
  const shiftName = new Map(shifts.map((s) => [s.id, s.name]));
  const term = params.q?.trim().toLowerCase();

  return (data ?? [])
    .map((row) => ({
      id: row.id,
      employeeCode: row.employee_code,
      name: row.name,
      department: row.department,
      designation: row.designation,
      mobile: row.mobile,
      branchName: row.branches.name,
      shiftName: row.shift_id ? (shiftName.get(row.shift_id) ?? null) : null,
      employmentType: row.employment_type as EmploymentType,
      joiningDate: row.joining_date,
      status: row.status as EmployeeStatus,
    }))
    .filter((row) =>
      !term ||
      row.name.toLowerCase().includes(term) ||
      row.employeeCode.toLowerCase().includes(term) ||
      (row.mobile ?? '').includes(term) ||
      (row.department ?? '').toLowerCase().includes(term),
    );
}

/**
 * The four totals are GENERATED columns, which introspection reports as
 * nullable because it cannot know they are always computed. fromDb() reads a
 * null as zero, so the shape is accepted as it comes back rather than asserted.
 */
function toSalary(row: {
  id: string; effective_from: string; effective_to: string | null;
  basic: string; hra: string; conveyance: string; medical_allowance: string;
  special_allowance: string; other_allowance: string; pf_employee: string;
  esi_employee: string; professional_tax: string; other_deduction: string;
  pf_employer: string; esi_employer: string; gross_earnings: string | null;
  total_deductions: string | null; net_payable: string | null; cost_to_company: string | null;
  revision_note: string | null;
}): SalaryStructure {
  const today = new Date().toISOString().slice(0, 10);
  return {
    id: row.id,
    effectiveFrom: row.effective_from,
    effectiveTo: row.effective_to,
    basic: fromDb(row.basic),
    hra: fromDb(row.hra),
    conveyance: fromDb(row.conveyance),
    medicalAllowance: fromDb(row.medical_allowance),
    specialAllowance: fromDb(row.special_allowance),
    otherAllowance: fromDb(row.other_allowance),
    pfEmployee: fromDb(row.pf_employee),
    esiEmployee: fromDb(row.esi_employee),
    professionalTax: fromDb(row.professional_tax),
    otherDeduction: fromDb(row.other_deduction),
    pfEmployer: fromDb(row.pf_employer),
    esiEmployer: fromDb(row.esi_employer),
    grossEarnings: fromDb(row.gross_earnings),
    totalDeductions: fromDb(row.total_deductions),
    netPayable: fromDb(row.net_payable),
    costToCompany: fromDb(row.cost_to_company),
    revisionNote: row.revision_note,
    current: row.effective_from <= today && (row.effective_to === null || row.effective_to >= today),
  };
}

export async function getEmployee(id: string): Promise<EmployeeRecord | null> {
  const context = await requirePermission('masters.employees.view');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase
    .from('employees')
    .select('id, employee_code, name, department, designation, mobile, email, personal_email, date_of_birth, gender, blood_group, emergency_contact, emergency_mobile, address_line1, address_line2, city, state, pincode, pan, aadhaar_last4, uan, esi_number, bank_account_name, bank_account_no, bank_ifsc, employment_type, probation_until, confirmed_on, joining_date, leaving_date, exit_type, exit_reason, reports_to, shift_id, status, branch_id, branches!inner ( name )')
    .eq('id', id)
    .maybeSingle();

  if (error) throw new Error(`Failed to load the employee: ${error.message}`);
  if (!data) return null;

  const canSeeSalary = context.permissions.has('hr.salary.view');

  // Each of these is separately gated by RLS, so a session without the
  // permission gets an empty list rather than an error — which is what makes
  // the page render sensibly for everyone (spec §52).
  const [salary, balances, documents, manager, shifts] = await Promise.all([
    supabase
      .from('employee_salary_structures')
      .select('id, effective_from, effective_to, basic, hra, conveyance, medical_allowance, special_allowance, other_allowance, pf_employee, esi_employee, professional_tax, other_deduction, pf_employer, esi_employer, gross_earnings, total_deductions, net_payable, cost_to_company, revision_note')
      .eq('employee_id', id)
      .order('effective_from', { ascending: false }),
    supabase
      .from('employee_leave_balances')
      .select('id, leave_type_id, financial_year, opening, accrued, used, encashed, balance')
      .eq('employee_id', id)
      .order('financial_year', { ascending: false }),
    supabase
      .from('employee_documents')
      .select('id, document_type, document_name, document_no, issued_on, expires_on, storage_path, notes')
      .eq('employee_id', id)
      .order('document_type'),
    data.reports_to
      ? supabase.from('employees').select('name').eq('id', data.reports_to).maybeSingle()
      : Promise.resolve({ data: null }),
    getLeaveTypes(),
  ]);

  const typeById = new Map(shifts.map((t) => [t.id, t]));

  return {
    id: data.id,
    employeeCode: data.employee_code,
    name: data.name,
    department: data.department,
    designation: data.designation,
    mobile: data.mobile,
    branchId: data.branch_id,
    branchName: data.branches.name,
    shiftName: null,
    shiftId: data.shift_id,
    employmentType: data.employment_type as EmploymentType,
    joiningDate: data.joining_date,
    status: data.status as EmployeeStatus,
    email: data.email,
    personalEmail: data.personal_email,
    dateOfBirth: data.date_of_birth,
    gender: data.gender,
    bloodGroup: data.blood_group,
    emergencyContact: data.emergency_contact,
    emergencyMobile: data.emergency_mobile,
    addressLine1: data.address_line1,
    addressLine2: data.address_line2,
    city: data.city,
    state: data.state,
    pincode: data.pincode,
    pan: data.pan,
    aadhaarLast4: data.aadhaar_last4,
    uan: data.uan,
    esiNumber: data.esi_number,
    bankAccountName: data.bank_account_name,
    bankAccountNo: data.bank_account_no,
    bankIfsc: data.bank_ifsc,
    probationUntil: data.probation_until,
    confirmedOn: data.confirmed_on,
    leavingDate: data.leaving_date,
    exitType: data.exit_type,
    exitReason: data.exit_reason,
    reportsToName: manager.data?.name ?? null,
    salaryHistory: (salary.data ?? []).map(toSalary),
    canSeeSalary,
    canManageSalary: context.permissions.has('hr.salary.manage'),
    leaveBalances: (balances.data ?? []).map((row) => ({
      id: row.id,
      leaveTypeId: row.leave_type_id,
      leaveTypeCode: typeById.get(row.leave_type_id)?.code ?? '—',
      leaveTypeName: typeById.get(row.leave_type_id)?.name ?? 'Leave',
      financialYear: row.financial_year,
      opening: Number(row.opening),
      accrued: Number(row.accrued),
      used: Number(row.used),
      encashed: Number(row.encashed),
      balance: Number(row.balance),
    })),
    documents: (documents.data ?? []).map((row) => ({
      id: row.id,
      documentType: row.document_type,
      documentName: row.document_name,
      documentNo: row.document_no,
      issuedOn: row.issued_on,
      expiresOn: row.expires_on,
      storagePath: row.storage_path,
      notes: row.notes,
      expiresInDays: daysUntil(row.expires_on),
    })),
  };
}

async function requireHr(permission: 'hr.settings.manage' | 'hr.salary.manage' | 'hr.leave.manage' | 'hr.documents.manage'): Promise<TenantContext> {
  const context = await requireTenantContext();
  if (!context.permissions.has(permission)) {
    throw new ForbiddenError(permission);
  }
  return context;
}

export interface SalaryStructureInput {
  readonly employeeId: string;
  readonly effectiveFrom: string;
  /** Rupees. */
  readonly basic: number;
  readonly hra: number;
  readonly conveyance: number;
  readonly medicalAllowance: number;
  readonly specialAllowance: number;
  readonly otherAllowance: number;
  readonly pfEmployee: number;
  readonly esiEmployee: number;
  readonly professionalTax: number;
  readonly otherDeduction: number;
  readonly pfEmployer: number;
  readonly esiEmployer: number;
  readonly revisionNote?: string | null;
}

/**
 * Adds a salary revision. Never an update: the row it supersedes keeps its
 * figures and is closed by trigger (spec §15).
 */
export async function addSalaryStructure(input: SalaryStructureInput): Promise<HrResult> {
  const context = await requireHr('hr.salary.manage');
  const supabase = await createSupabaseServerClient();

  if (!input.effectiveFrom) {
    return { ok: false, error: 'Say from which date this pay applies.' };
  }
  if (!(input.basic > 0)) {
    return { ok: false, error: 'Basic pay has to be greater than zero.' };
  }

  const { error } = await supabase.from('employee_salary_structures').insert({
    dealer_id: context.dealerId!,
    employee_id: input.employeeId,
    effective_from: input.effectiveFrom,
    basic: String(input.basic),
    hra: String(input.hra),
    conveyance: String(input.conveyance),
    medical_allowance: String(input.medicalAllowance),
    special_allowance: String(input.specialAllowance),
    other_allowance: String(input.otherAllowance),
    pf_employee: String(input.pfEmployee),
    esi_employee: String(input.esiEmployee),
    professional_tax: String(input.professionalTax),
    other_deduction: String(input.otherDeduction),
    pf_employer: String(input.pfEmployer),
    esi_employer: String(input.esiEmployer),
    revision_note: input.revisionNote?.trim() || null,
    created_by: context.userId,
  });

  if (error) {
    console.error('[hr] salary revision failed', error.message);
    return { ok: false, error: describeHrError(error.message) };
  }

  // The amounts are deliberately not written to the audit payload: the audit
  // trigger on the table already records the row, and audit_logs is readable
  // with admin.audit.view, which is not hr.salary.view (spec §52).
  await recordAudit({
    action: 'CREATE',
    entityType: 'employee_salary_structures',
    entityId: input.employeeId,
    dealerId: context.dealerId,
    branchId: context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
    newData: { employee_id: input.employeeId, effective_from: input.effectiveFrom },
  });

  return { ok: true, message: `Pay revised with effect from ${input.effectiveFrom}.` };
}

export interface ShiftInput {
  readonly id?: string | null;
  readonly code: string;
  readonly name: string;
  readonly startsAt: string;
  readonly endsAt: string;
  readonly breakMinutes: number;
  readonly graceMinutes: number;
  readonly weekOffDays: readonly number[];
  readonly halfDayMinutes: number;
  readonly fullDayMinutes: number;
}

export async function saveShift(input: ShiftInput): Promise<HrResult> {
  const context = await requireHr('hr.settings.manage');
  const supabase = await createSupabaseServerClient();

  if (!input.code.trim() || !input.name.trim()) {
    return { ok: false, error: 'A shift needs a code and a name.' };
  }
  if (input.startsAt === input.endsAt) {
    return { ok: false, error: 'A shift has to have some length.' };
  }

  const row = {
    dealer_id: context.dealerId!,
    code: input.code.trim().toUpperCase(),
    name: input.name.trim(),
    starts_at: input.startsAt,
    ends_at: input.endsAt,
    break_minutes: input.breakMinutes,
    grace_minutes: input.graceMinutes,
    week_off_days: [...input.weekOffDays],
    half_day_minutes: input.halfDayMinutes,
    full_day_minutes: input.fullDayMinutes,
  };

  const { error } = input.id
    ? await supabase.from('shifts').update({ ...row, updated_by: context.userId }).eq('id', input.id)
    : await supabase.from('shifts').insert({ ...row, created_by: context.userId });

  if (error) {
    return { ok: false, error: describeHrError(error.message) };
  }
  return { ok: true, message: input.id ? 'Shift updated.' : 'Shift added.' };
}

export interface LeaveTypeInput {
  readonly id?: string | null;
  readonly code: string;
  readonly name: string;
  readonly annualQuota: number;
  readonly isPaid: boolean;
  readonly carryForward: boolean;
  readonly maxCarryForward: number;
  readonly countsAsWorked: boolean;
}

export async function saveLeaveType(input: LeaveTypeInput): Promise<HrResult> {
  const context = await requireHr('hr.settings.manage');
  const supabase = await createSupabaseServerClient();

  if (!input.code.trim() || !input.name.trim()) {
    return { ok: false, error: 'A leave type needs a code and a name.' };
  }

  const row = {
    dealer_id: context.dealerId!,
    code: input.code.trim().toUpperCase(),
    name: input.name.trim(),
    annual_quota: String(input.annualQuota),
    is_paid: input.isPaid,
    carry_forward: input.carryForward,
    max_carry_forward: String(input.carryForward ? input.maxCarryForward : 0),
    counts_as_worked: input.countsAsWorked,
  };

  const { error } = input.id
    ? await supabase.from('leave_types').update({ ...row, updated_by: context.userId }).eq('id', input.id)
    : await supabase.from('leave_types').insert({ ...row, created_by: context.userId });

  if (error) {
    return { ok: false, error: describeHrError(error.message) };
  }
  return { ok: true, message: input.id ? 'Leave type updated.' : 'Leave type added.' };
}

export interface EmployeeHrInput {
  readonly id: string;
  readonly dateOfBirth?: string | null;
  readonly gender?: string | null;
  readonly bloodGroup?: string | null;
  readonly personalEmail?: string | null;
  readonly emergencyContact?: string | null;
  readonly emergencyMobile?: string | null;
  readonly addressLine1?: string | null;
  readonly city?: string | null;
  readonly state?: string | null;
  readonly pincode?: string | null;
  readonly pan?: string | null;
  readonly aadhaarLast4?: string | null;
  readonly uan?: string | null;
  readonly esiNumber?: string | null;
  readonly bankAccountName?: string | null;
  readonly bankAccountNo?: string | null;
  readonly bankIfsc?: string | null;
  readonly employmentType?: string | null;
  readonly probationUntil?: string | null;
  readonly confirmedOn?: string | null;
  readonly shiftId?: string | null;
  readonly reportsTo?: string | null;
}

const blank = (value: string | null | undefined): string | null => value?.trim() || null;

export async function updateEmployeeHr(input: EmployeeHrInput): Promise<HrResult> {
  const context = await requirePermission('masters.employees.manage');
  const supabase = await createSupabaseServerClient();

  const { error } = await supabase
    .from('employees')
    .update({
      date_of_birth: blank(input.dateOfBirth),
      gender: blank(input.gender) as 'MALE' | 'FEMALE' | 'OTHER' | null,
      blood_group: blank(input.bloodGroup),
      personal_email: blank(input.personalEmail),
      emergency_contact: blank(input.emergencyContact),
      emergency_mobile: blank(input.emergencyMobile),
      address_line1: blank(input.addressLine1),
      city: blank(input.city),
      state: blank(input.state),
      pincode: blank(input.pincode),
      pan: input.pan?.trim().toUpperCase() || null,
      aadhaar_last4: blank(input.aadhaarLast4),
      uan: blank(input.uan),
      esi_number: blank(input.esiNumber),
      bank_account_name: blank(input.bankAccountName),
      bank_account_no: blank(input.bankAccountNo),
      bank_ifsc: input.bankIfsc?.trim().toUpperCase() || null,
      employment_type: (blank(input.employmentType) ?? 'PERMANENT') as EmploymentType,
      probation_until: blank(input.probationUntil),
      confirmed_on: blank(input.confirmedOn),
      shift_id: blank(input.shiftId),
      reports_to: blank(input.reportsTo),
      updated_by: context.userId,
    })
    .eq('id', input.id);

  if (error) {
    console.error('[hr] employee update failed', error.message);
    return { ok: false, error: describeHrError(error.message) };
  }
  return { ok: true, id: input.id, message: 'The employee record was updated.' };
}

export interface LeaveBalanceInput {
  readonly employeeId: string;
  readonly leaveTypeId: string;
  readonly financialYear: string;
  readonly opening: number;
  readonly accrued: number;
  readonly used: number;
  readonly encashed: number;
}

export async function saveLeaveBalance(input: LeaveBalanceInput): Promise<HrResult> {
  const context = await requireHr('hr.leave.manage');
  const supabase = await createSupabaseServerClient();

  const { error } = await supabase
    .from('employee_leave_balances')
    .upsert(
      {
        dealer_id: context.dealerId!,
        employee_id: input.employeeId,
        leave_type_id: input.leaveTypeId,
        financial_year: input.financialYear,
        opening: String(input.opening),
        accrued: String(input.accrued),
        used: String(input.used),
        encashed: String(input.encashed),
        updated_by: context.userId,
      },
      { onConflict: 'employee_id,leave_type_id,financial_year' },
    );

  if (error) {
    return { ok: false, error: describeHrError(error.message) };
  }
  return { ok: true, message: 'Leave balance saved.' };
}

export interface DocumentInput {
  readonly employeeId: string;
  readonly documentType: string;
  readonly documentName: string;
  readonly documentNo?: string | null;
  readonly issuedOn?: string | null;
  readonly expiresOn?: string | null;
  readonly notes?: string | null;
}

export async function addEmployeeDocument(input: DocumentInput): Promise<HrResult> {
  const context = await requireHr('hr.documents.manage');
  const supabase = await createSupabaseServerClient();

  if (!input.documentName.trim()) {
    return { ok: false, error: 'Give the document a name.' };
  }

  const { error } = await supabase.from('employee_documents').insert({
    dealer_id: context.dealerId!,
    employee_id: input.employeeId,
    document_type: input.documentType as 'OTHER',
    document_name: input.documentName.trim(),
    document_no: blank(input.documentNo),
    issued_on: blank(input.issuedOn),
    expires_on: blank(input.expiresOn),
    notes: blank(input.notes),
    created_by: context.userId,
  });

  if (error) {
    return { ok: false, error: describeHrError(error.message) };
  }
  return { ok: true, message: 'Document recorded.' };
}

export async function removeEmployeeDocument(documentId: string): Promise<HrResult> {
  await requireHr('hr.documents.manage');
  const supabase = await createSupabaseServerClient();

  const { error } = await supabase.from('employee_documents').delete().eq('id', documentId);
  if (error) {
    return { ok: false, error: describeHrError(error.message) };
  }
  return { ok: true, message: 'Document removed.' };
}
