import 'server-only';

import { createSupabaseServerClient } from '@/lib/supabase/server';
import type { CustomerValues } from '@/lib/validation/customer';
import type { Tables } from '@/types/database.types';

/**
 * Customer data access.
 *
 * No `dealer_id` filter anywhere: RLS scopes every query to the caller's dealer.
 * A filter the application forgets is a leak; a policy it forgets still holds.
 */

export type Customer = Tables<'customers'>;

export const CUSTOMERS_PAGE_SIZE = 25;

export interface CustomerListResult {
  readonly rows: readonly Customer[];
  readonly total: number;
  readonly page: number;
  readonly pageCount: number;
}

/**
 * Search by Customer ID, mobile or name (spec §11).
 *
 * Registration and chassis search arrive with the vehicle module — a customer's
 * vehicles do not exist as records yet.
 */
export async function listCustomers(params: {
  readonly q?: string;
  readonly status: 'ALL' | 'ACTIVE' | 'INACTIVE' | 'BLOCKED';
  readonly page: number;
}): Promise<CustomerListResult> {
  const supabase = await createSupabaseServerClient();

  const from = (params.page - 1) * CUSTOMERS_PAGE_SIZE;
  let query = supabase
    .from('customers')
    .select('*', { count: 'exact' })
    .order('created_at', { ascending: false })
    .range(from, from + CUSTOMERS_PAGE_SIZE - 1);

  if (params.status !== 'ALL') {
    query = query.eq('status', params.status);
  }

  const term = params.q?.trim();
  if (term) {
    // PostgREST `or` takes a comma-separated filter list. Commas and parentheses
    // inside the term would be read as filter syntax, so they are stripped.
    const safe = term.replace(/[(),*]/g, ' ').trim();
    if (safe) {
      query = query.or(
        [
          `customer_code.ilike.*${safe}*`,
          `mobile.ilike.*${safe}*`,
          `alternate_mobile.ilike.*${safe}*`,
          `name.ilike.*${safe}*`,
          `gstin.ilike.*${safe}*`,
        ].join(','),
      );
    }
  }

  const { data, error, count } = await query;
  if (error) {
    throw new Error(`Failed to load customers: ${error.message}`);
  }

  const total = count ?? 0;
  return {
    rows: data ?? [],
    total,
    page: params.page,
    pageCount: Math.max(1, Math.ceil(total / CUSTOMERS_PAGE_SIZE)),
  };
}

export async function getCustomerById(id: string): Promise<Customer | null> {
  const supabase = await createSupabaseServerClient();
  const { data, error } = await supabase.from('customers').select('*').eq('id', id).maybeSingle();

  if (error) {
    throw new Error(`Failed to load customer: ${error.message}`);
  }
  return data;
}

/** An active customer already using this mobile, if any. Used for duplicate warnings. */
export async function findActiveByMobile(mobile: string, excludeId?: string): Promise<Customer | null> {
  const supabase = await createSupabaseServerClient();
  let query = supabase
    .from('customers')
    .select('*')
    .eq('mobile', mobile)
    .eq('status', 'ACTIVE')
    .limit(1);

  if (excludeId) {
    query = query.neq('id', excludeId);
  }

  const { data, error } = await query;
  if (error) {
    throw new Error(`Failed to check for a duplicate mobile: ${error.message}`);
  }
  return data?.[0] ?? null;
}

export async function insertCustomer(
  values: CustomerValues,
  context: { readonly dealerId: string; readonly userId: string },
): Promise<Customer> {
  const supabase = await createSupabaseServerClient();

  // customer_code is intentionally not set: the database trigger issues it.
  const { data, error } = await supabase
    .from('customers')
    .insert({
      dealer_id: context.dealerId,
      name: values.name,
      customer_type: values.customer_type,
      mobile: values.mobile,
      alternate_mobile: values.alternate_mobile ?? null,
      email: values.email ?? null,
      address_line1: values.address_line1 ?? null,
      address_line2: values.address_line2 ?? null,
      city: values.city ?? null,
      state: values.state ?? null,
      state_code: values.state_code ?? null,
      pincode: values.pincode ?? null,
      gstin: values.gstin ?? null,
      pan: values.pan ?? null,
      origin_branch_id: values.origin_branch_id ?? null,
      notes: values.notes ?? null,
      status: values.status,
      created_by: context.userId,
      updated_by: context.userId,
    })
    .select('*')
    .single();

  if (error) {
    throw error;
  }
  return data;
}

export async function updateCustomer(
  id: string,
  values: CustomerValues,
  context: { readonly userId: string },
): Promise<Customer> {
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase
    .from('customers')
    .update({
      name: values.name,
      customer_type: values.customer_type,
      mobile: values.mobile,
      alternate_mobile: values.alternate_mobile ?? null,
      email: values.email ?? null,
      address_line1: values.address_line1 ?? null,
      address_line2: values.address_line2 ?? null,
      city: values.city ?? null,
      state: values.state ?? null,
      state_code: values.state_code ?? null,
      pincode: values.pincode ?? null,
      gstin: values.gstin ?? null,
      pan: values.pan ?? null,
      origin_branch_id: values.origin_branch_id ?? null,
      notes: values.notes ?? null,
      status: values.status,
      updated_by: context.userId,
    })
    .eq('id', id)
    .select('*')
    .single();

  if (error) {
    throw error;
  }
  return data;
}

export interface CustomerStats {
  readonly total: number;
  readonly active: number;
  readonly business: number;
  readonly addedThisMonth: number;
}

export async function getCustomerStats(): Promise<CustomerStats> {
  const supabase = await createSupabaseServerClient();
  const monthStart = new Date();
  monthStart.setDate(1);
  monthStart.setHours(0, 0, 0, 0);

  const counted = async (build: (q: ReturnType<typeof base>) => ReturnType<typeof base>) => {
    const { count, error } = await build(base());
    if (error) {
      throw new Error(`Failed to load customer statistics: ${error.message}`);
    }
    return count ?? 0;
  };

  function base() {
    return supabase.from('customers').select('id', { count: 'exact', head: true });
  }

  const [total, active, business, addedThisMonth] = await Promise.all([
    counted((q) => q),
    counted((q) => q.eq('status', 'ACTIVE')),
    counted((q) => q.eq('customer_type', 'BUSINESS')),
    counted((q) => q.gte('created_at', monthStart.toISOString())),
  ]);

  return { total, active, business, addedThisMonth };
}
