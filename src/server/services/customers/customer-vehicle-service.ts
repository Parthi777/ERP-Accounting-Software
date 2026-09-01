import 'server-only';

import { requirePermission } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';

/**
 * The vehicles a dealer's customers own — spec §11.
 *
 * Two sources feed this register, and neither is a form someone remembers to
 * fill: delivery records the units the dealer sold, and a job card registers a
 * walk-in's vehicle by its registration number. That is why the page can be
 * searched by registration or chassis and reach a real record either way.
 */

export interface CustomerVehicleRow {
  readonly id: string;
  readonly customerId: string;
  readonly customerName: string;
  readonly customerCode: string;
  readonly mobile: string | null;
  readonly registrationNo: string | null;
  readonly chassisNo: string | null;
  readonly engineNo: string | null;
  readonly modelLabel: string | null;
  readonly colour: string | null;
  readonly purchaseDate: string | null;
  readonly status: string;
  /** True when the dealer sold this unit, rather than meeting it at the workshop. */
  readonly soldByUs: boolean;
}

export async function getCustomerVehicles(params: {
  readonly customerId?: string | null;
  readonly q?: string;
}): Promise<CustomerVehicleRow[]> {
  await requirePermission('customers.view');
  const supabase = await createSupabaseServerClient();

  let query = supabase
    .from('customer_vehicles')
    .select(
      'id, customer_id, vehicle_id, registration_no, chassis_no, engine_no, colour, purchase_date, status, customers!inner ( name, customer_code, mobile ), vehicle_models ( brand, name )',
    )
    .order('created_at', { ascending: false })
    .limit(500);

  if (params.customerId) {
    query = query.eq('customer_id', params.customerId);
  }

  const { data, error } = await query;
  if (error) {
    throw new Error(`Failed to load customer vehicles: ${error.message}`);
  }

  const term = params.q?.trim().toLowerCase();

  return (data ?? [])
    .map((row) => ({
      id: row.id,
      customerId: row.customer_id,
      customerName: row.customers.name,
      customerCode: row.customers.customer_code,
      mobile: row.customers.mobile,
      registrationNo: row.registration_no,
      chassisNo: row.chassis_no,
      engineNo: row.engine_no,
      modelLabel: row.vehicle_models
        ? `${row.vehicle_models.brand} ${row.vehicle_models.name}`
        : null,
      colour: row.colour,
      purchaseDate: row.purchase_date,
      status: row.status,
      soldByUs: row.vehicle_id !== null,
    }))
    .filter(
      (row) =>
        !term ||
        (row.registrationNo?.toLowerCase().includes(term) ?? false) ||
        (row.chassisNo?.toLowerCase().includes(term) ?? false) ||
        row.customerName.toLowerCase().includes(term) ||
        row.customerCode.toLowerCase().includes(term),
    );
}
