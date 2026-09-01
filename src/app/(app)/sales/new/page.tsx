import type { Metadata } from 'next';
import Link from 'next/link';
import { ArrowLeft } from 'lucide-react';

import { requirePermission } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { PageHeader } from '@/components/data-table/data-table';
import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { SaleForm } from '@/components/sales/sale-form';

export const metadata: Metadata = { title: 'New sale' };
export const dynamic = 'force-dynamic';

export default async function NewSalePage({
  searchParams,
}: {
  searchParams: Promise<{ booking?: string }>;
}) {
  const context = await requirePermission('sales.create');
  const params = await searchParams;
  const supabase = await createSupabaseServerClient();

  const [customers, vehicles, employees, bookingRow] = await Promise.all([
    supabase.from('customers').select('id, name, customer_code, mobile').eq('status', 'ACTIVE').order('name').limit(500),
    // Both IN_STOCK and BOOKED: a booked chassis is exactly what a conversion
    // needs to invoice.
    supabase
      .from('vehicles')
      .select('id, chassis_no, status, vehicle_models ( brand, name ), vehicle_variants ( name )')
      .in('status', ['IN_STOCK', 'BOOKED'])
      .order('stock_date')
      .limit(500),
    supabase.from('employees').select('id, name, employee_code').eq('status', 'ACTIVE').order('name'),
    params.booking
      ? supabase.from('bookings').select('id, booking_number, customer_id, status').eq('id', params.booking).maybeSingle()
      : Promise.resolve({ data: null }),
  ]);

  const booking = bookingRow.data && bookingRow.data.status === 'OPEN'
    ? { id: bookingRow.data.id, number: bookingRow.data.booking_number, customerId: bookingRow.data.customer_id }
    : null;

  const hasVehicles = (vehicles.data ?? []).length > 0;
  const hasCustomers = (customers.data ?? []).length > 0;

  return (
    <div className="mx-auto max-w-3xl">
      <Button variant="ghost" size="sm" asChild className="-ml-2 mb-2">
        <Link href="/sales"><ArrowLeft aria-hidden />Vehicle sales</Link>
      </Button>

      <PageHeader
        title="New sale"
        description="Lines are built from the price version in force on the invoice date."
      />

      {!context.activeBranch ? (
        <Panel className="p-6 text-sm text-ink-600">
          Choose a branch in the sidebar first — an invoice belongs to a branch.
        </Panel>
      ) : !hasCustomers || !hasVehicles ? (
        <Panel className="p-6 text-sm text-ink-600">
          <p className="font-medium text-ink-900">Something is missing first</p>
          <ul className="mt-2 space-y-1">
            {!hasCustomers && (
              <li>No active customers. <Link href="/customers/new" className="text-brand-600 hover:underline">Create one</Link>.</li>
            )}
            {!hasVehicles && (
              <li>No vehicles available. <Link href="/vehicles/upload" className="text-brand-600 hover:underline">Upload stock</Link>.</li>
            )}
          </ul>
        </Panel>
      ) : (
        <SaleForm
          branchName={context.activeBranch.name}
          booking={booking}
          customers={(customers.data ?? []).map((c) => ({
            id: c.id, label: `${c.name} · ${c.customer_code} · ${c.mobile}`,
          }))}
          vehicles={(vehicles.data ?? []).map((v) => ({
            id: v.id,
            label: v.chassis_no,
            sub: `${v.vehicle_models.brand} ${v.vehicle_models.name}${v.vehicle_variants?.name ? ' ' + v.vehicle_variants.name : ''}${v.status === 'BOOKED' ? ' (booked)' : ''}`,
          }))}
          employees={(employees.data ?? []).map((e) => ({ id: e.id, label: `${e.name} (${e.employee_code})` }))}
        />
      )}
    </div>
  );
}
