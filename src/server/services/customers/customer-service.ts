import 'server-only';

import { requirePermission, requireTenantContext } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { AppError, NotFoundError, ValidationError } from '@/server/errors';
import { customerSchema, type CustomerInput } from '@/lib/validation/customer';
import * as repository from '@/server/repositories/customer-repository';
import { recordAudit } from '@/server/services/audit/record-audit';

export type { Customer, CustomerListResult, CustomerStats } from '@/server/repositories/customer-repository';
export { CUSTOMERS_PAGE_SIZE } from '@/server/repositories/customer-repository';

/**
 * Customer master — spec §11.
 *
 * Every entry point asserts its permission first. Creation and updates re-validate
 * with the same Zod schema the form used, because the form's validation is a
 * convenience for the user and not a control: a request can arrive without ever
 * touching it.
 */

export async function searchCustomers(params: {
  readonly q?: string;
  readonly status: 'ALL' | 'ACTIVE' | 'INACTIVE' | 'BLOCKED';
  readonly page: number;
}) {
  await requirePermission('customers.view');
  return repository.listCustomers(params);
}

export async function getCustomer(id: string) {
  await requirePermission('customers.view');
  const customer = await repository.getCustomerById(id);
  if (!customer) {
    throw new NotFoundError('Customer');
  }
  return customer;
}

export async function getCustomerStats() {
  await requirePermission('customers.view');
  return repository.getCustomerStats();
}

export interface SaveResult {
  readonly ok: boolean;
  readonly id?: string;
  readonly customerCode?: string;
  readonly error?: string;
  readonly fieldErrors?: Readonly<Record<string, string>>;
}

export async function createCustomer(input: CustomerInput): Promise<SaveResult> {
  const context = await requirePermission('customers.create');

  const parsed = customerSchema.safeParse(input);
  if (!parsed.success) {
    return { ok: false, ...fieldErrorsFrom(parsed.error) };
  }

  if (!context.dealerId) {
    return { ok: false, error: 'Your account is not attached to a dealer.' };
  }

  // A friendly duplicate message beats a raw unique-violation, and the database
  // still has the final say if two requests race.
  const existing = await repository.findActiveByMobile(parsed.data.mobile);
  if (existing) {
    return {
      ok: false,
      fieldErrors: {
        mobile: `${existing.name} (${existing.customer_code}) already uses this mobile number.`,
      },
    };
  }

  try {
    const customer = await repository.insertCustomer(parsed.data, {
      dealerId: context.dealerId,
      userId: context.userId,
    });

    // The row change is captured by the database trigger; this records who did it
    // from which session, which the trigger cannot see.
    await recordAudit({
      action: 'CREATE',
      entityType: 'customers',
      entityId: customer.id,
      dealerId: context.dealerId,
      branchId: context.activeBranch?.id ?? null,
      userId: context.userId,
      userEmail: context.email,
      newData: { customer_code: customer.customer_code, name: customer.name },
    });

    return { ok: true, id: customer.id, customerCode: customer.customer_code };
  } catch (error) {
    return { ok: false, ...describeDatabaseError(error) };
  }
}

export async function updateCustomer(id: string, input: CustomerInput): Promise<SaveResult> {
  const context = await requirePermission('customers.edit');

  const parsed = customerSchema.safeParse(input);
  if (!parsed.success) {
    return { ok: false, ...fieldErrorsFrom(parsed.error) };
  }

  const before = await repository.getCustomerById(id);
  if (!before) {
    throw new NotFoundError('Customer');
  }

  if (parsed.data.mobile !== before.mobile && parsed.data.status === 'ACTIVE') {
    const existing = await repository.findActiveByMobile(parsed.data.mobile, id);
    if (existing) {
      return {
        ok: false,
        fieldErrors: {
          mobile: `${existing.name} (${existing.customer_code}) already uses this mobile number.`,
        },
      };
    }
  }

  try {
    const customer = await repository.updateCustomer(id, parsed.data, { userId: context.userId });

    await recordAudit({
      action: 'UPDATE',
      entityType: 'customers',
      entityId: customer.id,
      dealerId: context.dealerId,
      branchId: context.activeBranch?.id ?? null,
      userId: context.userId,
      userEmail: context.email,
      oldData: { name: before.name, mobile: before.mobile, status: before.status },
      newData: { name: customer.name, mobile: customer.mobile, status: customer.status },
    });

    return { ok: true, id: customer.id, customerCode: customer.customer_code };
  } catch (error) {
    return { ok: false, ...describeDatabaseError(error) };
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Error shaping — spec §55: show the user something useful, log the detail
// ─────────────────────────────────────────────────────────────────────────────

function fieldErrorsFrom(error: { issues: readonly { path: readonly PropertyKey[]; message: string }[] }) {
  const fieldErrors: Record<string, string> = {};
  for (const issue of error.issues) {
    const key = String(issue.path[0] ?? '');
    if (key && !fieldErrors[key]) {
      fieldErrors[key] = issue.message;
    }
  }
  return { fieldErrors, error: 'Please correct the highlighted fields.' };
}

/** Turns a Postgres constraint violation into something a user can act on. */
function describeDatabaseError(error: unknown): { error: string; fieldErrors?: Record<string, string> } {
  const code = (error as { code?: string })?.code;
  const message = (error as { message?: string })?.message ?? String(error);

  console.error('[customers] write failed', { code, message });

  if (code === '23505') {
    if (message.includes('customers_dealer_mobile_key')) {
      return {
        error: 'That mobile number already belongs to an active customer.',
        fieldErrors: { mobile: 'Already in use by another active customer.' },
      };
    }
    return { error: 'That record already exists.' };
  }

  if (code === '23514') {
    if (message.includes('mobile')) {
      return { error: 'Check the mobile number.', fieldErrors: { mobile: 'Not a valid Indian mobile number.' } };
    }
    if (message.includes('gstin')) {
      return { error: 'Check the GSTIN.', fieldErrors: { gstin: 'Not a valid GSTIN.' } };
    }
    if (message.includes('pan')) {
      return { error: 'Check the PAN.', fieldErrors: { pan: 'Not a valid PAN.' } };
    }
    return { error: 'Some of the details entered are not valid.' };
  }

  // RLS refused the write — the session lacks the permission, or is reaching
  // outside its own tenant.
  if (code === '42501' || message.includes('row-level security')) {
    return { error: 'You do not have permission to save this customer.' };
  }

  if (error instanceof AppError) {
    return { error: error.userMessage };
  }

  return { error: 'The customer could not be saved. Please try again.' };
}

/** Used by the detail page to say which modules will fill in the 360 view. */
export async function getCustomerContext() {
  return requireTenantContext();
}

export interface CustomerOption {
  readonly id: string;
  readonly label: string;
}

/**
 * Active customers as picker options, for forms elsewhere in the product that
 * need to attribute a transaction to a customer. Capped, because a select of
 * fifty thousand names is not a control anyone can use — those screens search
 * instead.
 */
export async function getCustomerOptions(limit = 500): Promise<CustomerOption[]> {
  await requirePermission('customers.view');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase
    .from('customers')
    .select('id, name, mobile')
    .eq('status', 'ACTIVE')
    .order('name')
    .limit(limit);

  if (error) {
    throw new Error(`Failed to load customers: ${error.message}`);
  }

  return (data ?? []).map((row) => ({
    id: row.id,
    label: row.mobile ? `${row.name} · ${row.mobile}` : row.name,
  }));
}

export { ValidationError };
