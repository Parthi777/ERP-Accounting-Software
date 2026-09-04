import 'server-only';

import { requireTenantContext, requirePermission, type TenantContext } from '@/server/auth/tenant-context';
import { ForbiddenError } from '@/server/errors';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { recordAudit } from '@/server/services/audit/record-audit';
import { fetchAttendance, isConfigured, type AttendanceRecord } from '@/server/services/hr/attendance-client';

/**
 * Attendance, mirrored from the external system — spec §12, §40, §59.
 *
 * The other system stays the source of truth for who clocked in. This layer
 * pulls its records into `attendance_days` and never asks it anything again, so
 * payroll and the reports read data held here — which is what lets a payslip be
 * re-run for March next year whether or not that subscription still exists.
 *
 * A failed pull changes nothing. The run is recorded FAILED with the vendor's
 * own error attached, yesterday's mirror is untouched, and the screen says how
 * stale it is. That is the rule spec §40 sets for the tax portal and it applies
 * just as well here.
 */

export type AttendanceStatus = 'PRESENT' | 'ABSENT' | 'HALF_DAY' | 'LEAVE' | 'WEEK_OFF' | 'HOLIDAY';

export interface AttendanceDay {
  readonly id: string;
  readonly employeeId: string;
  readonly date: string;
  readonly status: AttendanceStatus;
  readonly firstIn: string | null;
  readonly lastOut: string | null;
  readonly workedMinutes: number;
  readonly lateMinutes: number;
  readonly overtimeMinutes: number;
  readonly leaveTypeId: string | null;
  readonly source: 'SYNC' | 'MANUAL';
  readonly remarks: string | null;
}

export interface AttendanceSummaryRow {
  readonly employeeId: string;
  readonly employeeCode: string;
  readonly employeeName: string;
  readonly branchName: string;
  readonly presentDays: number;
  readonly leaveDays: number;
  readonly paidLeaveDays: number;
  readonly absentDays: number;
  readonly weekOffDays: number;
  readonly holidayDays: number;
  readonly payableDays: number;
  readonly lateCount: number;
  readonly overtimeMinutes: number;
  readonly recordedDays: number;
}

export interface SyncRun {
  readonly id: string;
  readonly fromDate: string;
  readonly toDate: string;
  readonly status: 'RUNNING' | 'SUCCESS' | 'PARTIAL' | 'FAILED';
  readonly fetchedCount: number;
  readonly matchedCount: number;
  readonly unmatchedCount: number;
  readonly writtenCount: number;
  readonly skippedManualCount: number;
  readonly lastError: string | null;
  readonly startedAt: string;
  readonly finishedAt: string | null;
}

export interface UnmappedEmployee {
  readonly id: string;
  readonly employeeCode: string;
  readonly name: string;
  readonly branchName: string;
}

export interface AttendanceOverview {
  /** False when no attendance system is connected at all. */
  readonly connected: boolean;
  readonly from: string;
  readonly to: string;
  readonly summary: readonly AttendanceSummaryRow[];
  readonly lastRun: SyncRun | null;
  readonly recentRuns: readonly SyncRun[];
  /** Employees with no external_ref — their attendance can never arrive. */
  readonly unmapped: readonly UnmappedEmployee[];
  readonly canSync: boolean;
  readonly canMap: boolean;
}

export interface AttendanceResult {
  readonly ok: boolean;
  readonly error?: string;
  readonly message?: string;
}

/** The importer takes a batch at a time; a year of a large payroll is not one call. */
const IMPORT_CHUNK = 500;

function toRun(row: {
  id: string; from_date: string; to_date: string; status: string;
  fetched_count: number; matched_count: number; unmatched_count: number;
  written_count: number; skipped_manual_count: number; last_error: string | null;
  started_at: string; finished_at: string | null;
}): SyncRun {
  return {
    id: row.id,
    fromDate: row.from_date,
    toDate: row.to_date,
    status: row.status as SyncRun['status'],
    fetchedCount: row.fetched_count,
    matchedCount: row.matched_count,
    unmatchedCount: row.unmatched_count,
    writtenCount: row.written_count,
    skippedManualCount: row.skipped_manual_count,
    lastError: row.last_error,
    startedAt: row.started_at,
    finishedAt: row.finished_at,
  };
}

export async function getAttendanceOverview(params: {
  readonly from: string;
  readonly to: string;
  readonly branchId?: string | null;
}): Promise<AttendanceOverview> {
  const context = await requirePermission('hr.attendance.view');
  const supabase = await createSupabaseServerClient();

  const branchId =
    params.branchId ?? (context.hasAllBranchAccess ? null : (context.activeBranch?.id ?? null));

  const [summary, runs, unmapped] = await Promise.all([
    supabase.rpc('attendance_summary', {
      p_from: params.from,
      p_to: params.to,
      p_branch_id: branchId,
    }),
    supabase
      .from('attendance_sync_runs')
      .select('id, from_date, to_date, status, fetched_count, matched_count, unmatched_count, written_count, skipped_manual_count, last_error, started_at, finished_at')
      .order('started_at', { ascending: false })
      .limit(10),
    supabase
      .from('employees')
      .select('id, employee_code, name, branches!inner ( name )')
      .is('external_ref', null)
      .in('status', ['ACTIVE', 'ON_LEAVE'])
      .order('employee_code')
      .limit(200),
  ]);

  if (summary.error) {
    throw new Error(`Failed to load the attendance register: ${summary.error.message}`);
  }

  const recentRuns = (runs.data ?? []).map(toRun);

  return {
    connected: isConfigured(),
    from: params.from,
    to: params.to,
    summary: (summary.data ?? []).map((row) => ({
      employeeId: row.employee_id,
      employeeCode: row.employee_code,
      employeeName: row.employee_name,
      branchName: row.branch_name,
      presentDays: Number(row.present_days),
      leaveDays: Number(row.leave_days),
      paidLeaveDays: Number(row.paid_leave_days),
      absentDays: row.absent_days,
      weekOffDays: row.week_off_days,
      holidayDays: row.holiday_days,
      payableDays: Number(row.payable_days),
      lateCount: row.late_count,
      overtimeMinutes: row.overtime_minutes,
      recordedDays: row.recorded_days,
    })),
    lastRun: recentRuns[0] ?? null,
    recentRuns,
    unmapped: (unmapped.data ?? []).map((row) => ({
      id: row.id,
      employeeCode: row.employee_code,
      name: row.name,
      branchName: row.branches.name,
    })),
    canSync: context.permissions.has('hr.attendance.sync'),
    canMap: context.permissions.has('hr.mapping.manage'),
  };
}

async function requireHr(permission: 'hr.attendance.sync' | 'hr.attendance.edit' | 'hr.mapping.manage'): Promise<TenantContext> {
  const context = await requireTenantContext();
  if (!context.permissions.has(permission)) {
    throw new ForbiddenError(permission);
  }
  return context;
}

/**
 * Pulls a date range from the external system into the mirror.
 *
 * The order matters and is the whole point: open the run, call the vendor, and
 * only then write. A failure at the vendor closes the run FAILED and leaves the
 * mirror exactly as it was — the previous sync's data is still there, still
 * usable, and the screen says how old it is.
 */
export async function syncAttendance(params: {
  readonly from: string;
  readonly to: string;
}): Promise<AttendanceResult> {
  const context = await requireHr('hr.attendance.sync');
  const supabase = await createSupabaseServerClient();

  if (!isConfigured()) {
    return {
      ok: false,
      error: 'No attendance system is connected. Add its API details to the environment first.',
    };
  }

  const { data: runId, error: startError } = await supabase.rpc('start_attendance_sync', {
    p_from: params.from,
    p_to: params.to,
  });

  if (startError || !runId) {
    return { ok: false, error: startError?.message ?? 'The sync could not be started.' };
  }

  const fetched = await fetchAttendance(params.from, params.to);

  if (!fetched.ok) {
    // The vendor failed. Record why, change nothing else (spec §40).
    await supabase.rpc('finish_attendance_sync', {
      p_run_id: runId,
      p_status: 'FAILED',
      p_error: fetched.message,
      // The vendor's own words, kept for whoever has to ring their support desk.
      // Stringified because `raw` is whatever came back, and a jsonb column
      // wants something it can actually hold.
      p_detail: {
        status: fetched.status ?? null,
        raw: fetched.raw === undefined || fetched.raw === null ? null : String(fetched.raw),
      },
    });
    console.error('[attendance] sync failed', fetched.message);
    return { ok: false, error: fetched.message };
  }

  let matched = 0;
  let unmatched = 0;
  let written = 0;
  let skipped = 0;
  let importError: string | null = null;

  for (let i = 0; i < fetched.records.length; i += IMPORT_CHUNK) {
    const chunk = fetched.records.slice(i, i + IMPORT_CHUNK).map(toImportRow);

    const { data, error } = await supabase.rpc('import_attendance_days', {
      p_run_id: runId,
      p_rows: chunk,
    });

    if (error) {
      importError = error.message;
      break;
    }
    const row = Array.isArray(data) ? data[0] : data;
    matched += row?.matched ?? 0;
    unmatched += row?.unmatched ?? 0;
    written += row?.written ?? 0;
    skipped += row?.skipped_manual ?? 0;
  }

  // PARTIAL, not SUCCESS, whenever something did not land. A run that says
  // SUCCESS while half a branch is unmatched is how a payroll goes out wrong.
  const status = importError ? 'FAILED' : unmatched > 0 ? 'PARTIAL' : 'SUCCESS';

  await supabase.rpc('finish_attendance_sync', {
    p_run_id: runId,
    p_status: status,
    p_error: importError,
    p_detail: null,
  });

  await recordAudit({
    action: 'UPDATE',
    entityType: 'attendance_sync_runs',
    entityId: String(runId),
    dealerId: context.dealerId,
    branchId: context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
    newData: { from: params.from, to: params.to, status, matched, unmatched, written },
  });

  if (importError) {
    return { ok: false, error: `The attendance could not be written: ${importError}` };
  }

  const parts = [`${written} day${written === 1 ? '' : 's'} updated`];
  if (skipped > 0) parts.push(`${skipped} left as corrected by hand`);
  if (unmatched > 0) {
    parts.push(
      `${unmatched} record${unmatched === 1 ? '' : 's'} matched no employee here — map them, or their pay will be wrong`,
    );
  }

  return { ok: true, message: `${parts.join('. ')}.` };
}

/** The record shape `import_attendance_days` expects. */
function toImportRow(record: AttendanceRecord) {
  return {
    external_ref: record.employeeRef,
    date: record.date,
    status: record.status,
    first_in: record.firstIn ?? null,
    last_out: record.lastOut ?? null,
    worked_minutes: record.workedMinutes ?? 0,
    late_minutes: record.lateMinutes ?? 0,
    early_exit_minutes: record.earlyExitMinutes ?? 0,
    overtime_minutes: record.overtimeMinutes ?? 0,
    leave_code: record.leaveCode ?? null,
    record_ref: record.recordRef ?? null,
    remarks: record.remarks ?? null,
  };
}

/**
 * Maps one employee to their record in the external system.
 *
 * Matching is by this reference and nothing else, so setting it wrong attributes
 * someone else's attendance to this person. The unique index refuses a reference
 * already used by another employee, which is the case that would otherwise split
 * one person's month across two records.
 */
export async function mapEmployee(params: {
  readonly employeeId: string;
  readonly externalRef: string | null;
}): Promise<AttendanceResult> {
  const context = await requireHr('hr.mapping.manage');
  const supabase = await createSupabaseServerClient();

  const ref = params.externalRef?.trim() || null;

  const { error } = await supabase
    .from('employees')
    .update({ external_ref: ref, updated_by: context.userId })
    .eq('id', params.employeeId);

  if (error) {
    if (error.message.includes('employees_external_ref_key')) {
      return {
        ok: false,
        error: 'Another employee is already mapped to that reference. One external record belongs to one person.',
      };
    }
    return { ok: false, error: error.message };
  }

  await recordAudit({
    action: 'UPDATE',
    entityType: 'employees',
    entityId: params.employeeId,
    dealerId: context.dealerId,
    branchId: context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
    newData: { external_ref: ref },
  });

  return { ok: true, message: ref ? 'Employee mapped.' : 'Mapping removed.' };
}

/** One employee's days, for the register and for checking a correction. */
export async function getEmployeeAttendance(params: {
  readonly employeeId: string;
  readonly from: string;
  readonly to: string;
}): Promise<readonly AttendanceDay[]> {
  await requirePermission('hr.attendance.view');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase
    .from('attendance_days')
    .select('id, employee_id, attendance_date, status, first_in, last_out, worked_minutes, late_minutes, overtime_minutes, leave_type_id, source, remarks')
    .eq('employee_id', params.employeeId)
    .gte('attendance_date', params.from)
    .lte('attendance_date', params.to)
    .order('attendance_date');

  if (error) {
    throw new Error(`Failed to load attendance: ${error.message}`);
  }

  return (data ?? []).map((row) => ({
    id: row.id,
    employeeId: row.employee_id,
    date: row.attendance_date,
    status: row.status as AttendanceStatus,
    firstIn: row.first_in,
    lastOut: row.last_out,
    workedMinutes: row.worked_minutes,
    lateMinutes: row.late_minutes,
    overtimeMinutes: row.overtime_minutes,
    leaveTypeId: row.leave_type_id,
    source: row.source as 'SYNC' | 'MANUAL',
    remarks: row.remarks,
  }));
}
