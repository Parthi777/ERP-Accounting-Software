'use server';

import { revalidatePath } from 'next/cache';

import * as service from '@/server/services/hr/hr-service';
import { toAppError } from '@/server/errors';

/**
 * HR — spec §12, §15.
 *
 * Nothing here posts to the ledger; payroll will, when it is built on top of
 * this. So the pages revalidated are HR's own.
 */
function refresh(employeeId?: string) {
  revalidatePath('/hr');
  revalidatePath('/hr/settings');
  revalidatePath('/masters/employees');
  if (employeeId) revalidatePath(`/hr/${employeeId}`);
}

export async function updateEmployeeHrAction(
  input: service.EmployeeHrInput,
): Promise<service.HrResult> {
  try {
    const result = await service.updateEmployeeHr(input);
    if (result.ok) refresh(input.id);
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function addSalaryStructureAction(
  input: service.SalaryStructureInput,
): Promise<service.HrResult> {
  try {
    const result = await service.addSalaryStructure(input);
    if (result.ok) refresh(input.employeeId);
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function saveShiftAction(input: service.ShiftInput): Promise<service.HrResult> {
  try {
    const result = await service.saveShift(input);
    if (result.ok) refresh();
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function saveLeaveTypeAction(input: service.LeaveTypeInput): Promise<service.HrResult> {
  try {
    const result = await service.saveLeaveType(input);
    if (result.ok) refresh();
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function saveLeaveBalanceAction(
  input: service.LeaveBalanceInput,
): Promise<service.HrResult> {
  try {
    const result = await service.saveLeaveBalance(input);
    if (result.ok) refresh(input.employeeId);
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function addEmployeeDocumentAction(
  input: service.DocumentInput,
): Promise<service.HrResult> {
  try {
    const result = await service.addEmployeeDocument(input);
    if (result.ok) refresh(input.employeeId);
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}

export async function removeEmployeeDocumentAction(
  documentId: string,
  employeeId: string,
): Promise<service.HrResult> {
  try {
    const result = await service.removeEmployeeDocument(documentId);
    if (result.ok) refresh(employeeId);
    return result;
  } catch (error) {
    return { ok: false, error: toAppError(error).userMessage };
  }
}
