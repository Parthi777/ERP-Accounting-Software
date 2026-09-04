import 'server-only';

import { serverEnv } from '@/config/env';

/**
 * The external attendance system's client — spec §40.
 *
 * ─────────────────────────────────────────────────────────────────────────────
 * THIS IS THE ONLY FILE THAT KNOWS THE ATTENDANCE VENDOR EXISTS.
 * ─────────────────────────────────────────────────────────────────────────────
 *
 * Everything above it deals in "give me attendance between these dates, here is
 * what came back". Swapping vendors, or moving from one API to another, changes
 * this file and nothing else — the same seam irp-client.ts gives the tax portal.
 *
 * Three rules, all from spec §40 and all deliberate:
 *
 *   1. **A vendor failure must never corrupt what is already mirrored.** Nothing
 *      here writes to the database, and every failure path returns a result
 *      rather than throwing. The sync run ends FAILED and yesterday's mirrored
 *      attendance is exactly as it was.
 *
 *   2. **Store the technical error, show a readable one.** `message` is for
 *      whoever pressed Sync; `status` and `raw` go into the run for whoever has
 *      to ring the vendor.
 *
 *   3. **Unconfigured is not an error.** A dealer who has not connected an
 *      attendance system should see "not connected", not a stack trace.
 *      `isConfigured()` is how callers ask before offering the button.
 *
 * ── Fitting this to YOUR vendor ─────────────────────────────────────────────
 *
 * `fetchAttendance` below is written against the shape most attendance APIs
 * use — GET with a date range, a bearer token, and an array of day records. If
 * yours differs, `buildRequest` and `normalise` are the two functions to change
 * and they are deliberately small. What must NOT change is the returned
 * `AttendanceRecord` shape: the mirror and the importer are built on it.
 *
 * In particular `employeeRef` must be the vendor's stable id for the person,
 * because that is what `employees.external_ref` is matched against. Matching on
 * a name would eventually attribute one person's attendance to another.
 */

/** One person's one day, as this application understands it. */
export interface AttendanceRecord {
  /** The vendor's id for the employee — matched to employees.external_ref. */
  readonly employeeRef: string;
  /** ISO date, YYYY-MM-DD. */
  readonly date: string;
  readonly status: 'PRESENT' | 'ABSENT' | 'HALF_DAY' | 'LEAVE' | 'WEEK_OFF' | 'HOLIDAY';
  /** HH:MM, when the day was worked. */
  readonly firstIn?: string | null;
  readonly lastOut?: string | null;
  readonly workedMinutes?: number;
  readonly lateMinutes?: number;
  readonly earlyExitMinutes?: number;
  readonly overtimeMinutes?: number;
  /** The vendor's leave code, matched against this dealer's leave_types.code. */
  readonly leaveCode?: string | null;
  /** The vendor's id for the record itself, kept so a re-pull can be traced. */
  readonly recordRef?: string | null;
  readonly remarks?: string | null;
}

export type AttendanceFetch =
  | { readonly ok: true; readonly records: readonly AttendanceRecord[] }
  | {
      readonly ok: false;
      /** For the operator. */
      readonly message: string;
      /** For the run record, and for the vendor's support desk. */
      readonly status?: number;
      readonly raw?: unknown;
    };

export interface AttendanceConfig {
  readonly baseUrl: string;
  readonly apiKey: string;
  readonly auth: 'bearer' | 'header' | 'basic';
  readonly keyHeader: string;
  readonly path: string;
}

/** Whether an attendance system is connected at all. */
export function isConfigured(): boolean {
  const env = serverEnv();
  return Boolean(env.ATTENDANCE_API_BASE_URL && env.ATTENDANCE_API_KEY);
}

function config(): AttendanceConfig | null {
  const env = serverEnv();
  if (!env.ATTENDANCE_API_BASE_URL || !env.ATTENDANCE_API_KEY) {
    return null;
  }
  return {
    baseUrl: env.ATTENDANCE_API_BASE_URL.replace(/\/+$/, ''),
    apiKey: env.ATTENDANCE_API_KEY,
    auth: env.ATTENDANCE_API_AUTH,
    keyHeader: env.ATTENDANCE_API_KEY_HEADER,
    path: env.ATTENDANCE_API_PATH.startsWith('/')
      ? env.ATTENDANCE_API_PATH
      : `/${env.ATTENDANCE_API_PATH}`,
  };
}

/**
 * Where the vendor's request shape lives. Change this and `normalise` to fit a
 * different API; nothing else in the codebase needs to know.
 */
function buildRequest(c: AttendanceConfig, from: string, to: string): Request {
  const url = new URL(`${c.baseUrl}${c.path}`);
  url.searchParams.set('from', from);
  url.searchParams.set('to', to);

  const headers: Record<string, string> = { accept: 'application/json' };
  if (c.auth === 'bearer') {
    headers.authorization = `Bearer ${c.apiKey}`;
  } else if (c.auth === 'basic') {
    headers.authorization = `Basic ${Buffer.from(c.apiKey).toString('base64')}`;
  } else {
    headers[c.keyHeader] = c.apiKey;
  }

  return new Request(url, { method: 'GET', headers });
}

/** Reads whichever of the usual envelopes the vendor wraps its array in. */
function extractArray(body: unknown): unknown[] {
  if (Array.isArray(body)) return body;
  if (body && typeof body === 'object') {
    for (const key of ['data', 'records', 'results', 'items', 'attendance']) {
      const value = (body as Record<string, unknown>)[key];
      if (Array.isArray(value)) return value;
    }
  }
  return [];
}

function pick(row: Record<string, unknown>, ...keys: string[]): string | null {
  for (const key of keys) {
    const value = row[key];
    if (typeof value === 'string' && value.trim() !== '') return value.trim();
    if (typeof value === 'number') return String(value);
  }
  return null;
}

function pickNumber(row: Record<string, unknown>, ...keys: string[]): number | undefined {
  for (const key of keys) {
    const value = row[key];
    if (typeof value === 'number' && Number.isFinite(value)) return value;
    if (typeof value === 'string' && value.trim() !== '' && Number.isFinite(Number(value))) {
      return Number(value);
    }
  }
  return undefined;
}

/** HH:MM out of "09:28", "09:28:11" or an ISO timestamp. */
function toTime(value: string | null): string | null {
  if (!value) return null;
  const hm = /(\d{1,2}):(\d{2})/.exec(value);
  if (!hm) return null;
  return `${hm[1]!.padStart(2, '0')}:${hm[2]}`;
}

const STATUSES = new Set(['PRESENT', 'ABSENT', 'HALF_DAY', 'LEAVE', 'WEEK_OFF', 'HOLIDAY']);

/**
 * The vendor's row becomes an AttendanceRecord here.
 *
 * Written to accept the field names these APIs commonly use rather than one
 * fixed spelling, so it stands a chance of working before anyone tunes it. A row
 * without an employee reference or a date is dropped: the importer matches on
 * that reference, and a row it cannot attribute is worse than a missing one.
 */
function normalise(raw: unknown): AttendanceRecord | null {
  if (!raw || typeof raw !== 'object') return null;
  const row = raw as Record<string, unknown>;

  const employeeRef = pick(row, 'employee_id', 'employeeId', 'employee_code', 'employeeCode', 'emp_code', 'empId', 'user_id');
  const date = pick(row, 'date', 'attendance_date', 'attendanceDate', 'day');
  if (!employeeRef || !date) return null;

  const isoDate = /^\d{4}-\d{2}-\d{2}/.exec(date)?.[0];
  if (!isoDate) return null;

  const rawStatus = (pick(row, 'status', 'attendance_status', 'day_status') ?? '')
    .toUpperCase()
    .replace(/[\s-]+/g, '_');

  const status = STATUSES.has(rawStatus)
    ? (rawStatus as AttendanceRecord['status'])
    : rawStatus === 'P' ? 'PRESENT'
    : rawStatus === 'A' ? 'ABSENT'
    : rawStatus === 'HD' || rawStatus === 'HALF' ? 'HALF_DAY'
    : rawStatus === 'L' ? 'LEAVE'
    : rawStatus === 'WO' || rawStatus === 'WEEKOFF' ? 'WEEK_OFF'
    : rawStatus === 'H' ? 'HOLIDAY'
    : 'ABSENT';

  return {
    employeeRef,
    date: isoDate,
    status,
    firstIn: toTime(pick(row, 'first_in', 'firstIn', 'in_time', 'inTime', 'punch_in', 'check_in')),
    lastOut: toTime(pick(row, 'last_out', 'lastOut', 'out_time', 'outTime', 'punch_out', 'check_out')),
    workedMinutes: pickNumber(row, 'worked_minutes', 'workedMinutes', 'work_minutes', 'duration_minutes'),
    lateMinutes: pickNumber(row, 'late_minutes', 'lateMinutes', 'late_by_minutes'),
    earlyExitMinutes: pickNumber(row, 'early_exit_minutes', 'earlyExitMinutes', 'early_going_minutes'),
    overtimeMinutes: pickNumber(row, 'overtime_minutes', 'overtimeMinutes', 'ot_minutes'),
    leaveCode: pick(row, 'leave_code', 'leaveCode', 'leave_type', 'leaveType'),
    recordRef: pick(row, 'id', 'record_id', 'recordId', 'attendance_id'),
    remarks: pick(row, 'remarks', 'note', 'notes', 'comment'),
  };
}

/**
 * Fetches a date range from the vendor.
 *
 * Never throws. A network failure, a 500, a bad payload — all come back as
 * `ok: false` with something the operator can read, because the caller's job is
 * to record a failed run, not to crash a page (spec §40, §55).
 */
export async function fetchAttendance(from: string, to: string): Promise<AttendanceFetch> {
  const c = config();
  if (!c) {
    return {
      ok: false,
      message:
        'No attendance system is connected. Set ATTENDANCE_API_BASE_URL and ATTENDANCE_API_KEY to connect one.',
    };
  }

  let response: Response;
  try {
    response = await fetch(buildRequest(c, from, to), {
      // A vendor that hangs must not hold a request open indefinitely.
      signal: AbortSignal.timeout(30_000),
      cache: 'no-store',
    });
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    return {
      ok: false,
      message: 'The attendance system could not be reached. Nothing was changed.',
      raw: reason,
    };
  }

  const text = await response.text();

  if (!response.ok) {
    return {
      ok: false,
      message:
        response.status === 401 || response.status === 403
          ? 'The attendance system rejected the credentials. Check the API key.'
          : `The attendance system returned an error (${response.status}). Nothing was changed.`,
      status: response.status,
      raw: text.slice(0, 2000),
    };
  }

  let body: unknown;
  try {
    body = JSON.parse(text);
  } catch {
    return {
      ok: false,
      message: 'The attendance system did not return JSON. Nothing was changed.',
      status: response.status,
      raw: text.slice(0, 2000),
    };
  }

  const rows = extractArray(body);
  const records = rows
    .map(normalise)
    .filter((record): record is AttendanceRecord => record !== null);

  // Rows arrived but none survived normalising: the field names do not match
  // what this client expects, which is a configuration problem and not an empty
  // month. Saying so is what stops someone assuming nobody came to work.
  if (rows.length > 0 && records.length === 0) {
    return {
      ok: false,
      message:
        'The attendance system returned records this application could not read. ' +
        'The field names likely differ — see attendance-client.ts.',
      status: response.status,
      raw: JSON.stringify(rows[0]).slice(0, 2000),
    };
  }

  return { ok: true, records };
}
