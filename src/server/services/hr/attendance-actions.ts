'use server';

import { revalidatePath } from 'next/cache';

import * as service from '@/server/services/hr/attendance-service';
import { toAppError } from '@/server/errors';

/**
 * Attendance — spec §12, §40.
 *
 * A sync reaches an external system, so it can be slow and it can fail. Both are
 * ordinary outcomes here: the action returns a result either way and the page
 * shows how stale the mirror is.
 */
function refresh() {
  revalidatePath('/hr/attendance');
  revalidatePath('/hr');
}

export async function syncAttendanceAction(params: {
  from: string;
  to: string;
}): Promise<service.AttendanceResult> {
  try {
    const result = await service.syncAttendance(params);
    // Even a failed run is worth re-reading: the run record now shows the error.
    refresh();
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function mapEmployeeAction(params: {
  employeeId: string;
  externalRef: string | null;
}): Promise<service.AttendanceResult> {
  try {
    const result = await service.mapEmployee(params);
    if (result.ok) {
      refresh();
      revalidatePath(`/hr/${params.employeeId}`);
    }
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}
