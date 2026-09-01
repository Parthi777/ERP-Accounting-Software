import type { Metadata } from 'next';
import Link from 'next/link';
import { ArrowLeft } from 'lucide-react';

import { requirePermission } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { PageHeader } from '@/components/data-table/data-table';
import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { BookingForm } from '@/components/sales/booking-form';

export const metadata: Metadata = { title: 'New booking' };
export const dynamic = 'force-dynamic';

export default async function NewBookingPage() {
  const context = await requirePermission('bookings.create');
  const supabase = await createSupabaseServerClient();

  // RLS scopes each of these to the dealer, and vehicles additionally to the
  // branches this user can reach.
  const [customers, models, variants, vehicles, employees] = await Promise.all([
    supabase.from('customers').select('id, name, customer_code, mobile').eq('status', 'ACTIVE').order('name').limit(500),
    supabase.from('vehicle_models').select('id, brand, name').eq('status', 'ACTIVE').order('brand'),
    supabase.from('vehicle_variants').select('id, name, model_id').eq('status', 'ACTIVE').order('name'),
    supabase.from('vehicles').select('id, chassis_no, model_id, vehicle_variants ( name )').eq('status', 'IN_STOCK').order('stock_date').limit(500),
    supabase.from('employees').select('id, name, employee_code').eq('status', 'ACTIVE').order('name'),
  ]);

  const hasCustomers = (customers.data ?? []).length > 0;
  const hasModels = (models.data ?? []).length > 0;

  return (
    <div className="mx-auto max-w-3xl">
      <Button variant="ghost" size="sm" asChild className="-ml-2 mb-2">
        <Link href="/bookings"><ArrowLeft aria-hidden />Bookings</Link>
      </Button>

      <PageHeader
        title="New booking"
        description="Creates the booking, its advance receipt and the accounting entry together."
      />

      {!context.activeBranch ? (
        <Panel className="p-6 text-sm text-ink-600">
          Choose a branch in the sidebar before creating a booking — a booking belongs to a branch.
        </Panel>
      ) : !hasCustomers || !hasModels ? (
        <Panel className="p-6 text-sm text-ink-600">
          <p className="font-medium text-ink-900">Something is missing first</p>
          <ul className="mt-2 space-y-1">
            {!hasCustomers && (
              <li>
                No active customers. <Link href="/customers/new" className="text-brand-600 hover:underline">Create one</Link>.
              </li>
            )}
            {!hasModels && (
              <li>
                No active vehicle models. <Link href="/vehicles/models/new" className="text-brand-600 hover:underline">Create one</Link>.
              </li>
            )}
          </ul>
        </Panel>
      ) : (
        <BookingForm
          branchName={context.activeBranch.name}
          customers={(customers.data ?? []).map((c) => ({
            id: c.id,
            label: `${c.name} · ${c.customer_code} · ${c.mobile}`,
          }))}
          models={(models.data ?? []).map((m) => ({ id: m.id, label: `${m.brand} ${m.name}` }))}
          variants={(variants.data ?? []).map((v) => ({ id: v.id, label: v.name, modelId: v.model_id }))}
          vehicles={(vehicles.data ?? []).map((v) => ({
            id: v.id,
            label: v.chassis_no,
            modelId: v.model_id,
            sub: v.vehicle_variants?.name ?? undefined,
          }))}
          employees={(employees.data ?? []).map((e) => ({ id: e.id, label: `${e.name} (${e.employee_code})` }))}
        />
      )}
    </div>
  );
}
