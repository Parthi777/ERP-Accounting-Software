import type { Metadata } from 'next';
import Link from 'next/link';
import { notFound } from 'next/navigation';
import { ArrowLeft, Pencil } from 'lucide-react';

import { getCustomer } from '@/server/services/customers/customer-service';
import { requireTenantContext } from '@/server/auth/tenant-context';
import { NotFoundError } from '@/server/errors';
import { Panel, PanelContent, PanelHeader, PanelTitle } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { formatDate, formatDateTime, formatMobile } from '@/lib/format';

export const metadata: Metadata = { title: 'Customer' };
export const dynamic = 'force-dynamic';

const STATUS_TONE: Record<string, 'positive' | 'neutral' | 'danger'> = {
  ACTIVE: 'positive',
  INACTIVE: 'neutral',
  BLOCKED: 'danger',
};

/**
 * Customer 360 (spec §11).
 *
 * Identity is real. The related sections — bookings, sales, payments, finance,
 * service — name the module that will fill them rather than showing an empty
 * table that reads as broken.
 */
const RELATED = [
  { label: 'Bookings', phase: 4, note: 'Booking history and advances' },
  { label: 'Vehicle Sales', phase: 4, note: 'Invoices, chassis and delivery' },
  { label: 'Payments', phase: 5, note: 'Receipts and outstanding' },
  { label: 'Finance', phase: 4, note: 'HP applications and disbursement' },
  { label: 'Service', phase: 6, note: 'Job cards and service invoices' },
  { label: 'Ledger', phase: 5, note: 'Running account from the general ledger' },
];

export default async function CustomerDetailPage({
  params,
}: {
  params: Promise<{ id: string }>;
}) {
  const { id } = await params;
  const context = await requireTenantContext();

  let customer;
  try {
    customer = await getCustomer(id);
  } catch (error) {
    if (error instanceof NotFoundError) {
      notFound();
    }
    throw error;
  }

  const canEdit = context.permissions.has('customers.edit');
  const branch = context.accessibleBranches.find((b) => b.id === customer.origin_branch_id);

  const identity: { label: string; value: string }[] = [
    { label: 'Customer ID', value: customer.customer_code },
    { label: 'Type', value: customer.customer_type === 'BUSINESS' ? 'Business' : 'Individual' },
    { label: 'Mobile', value: formatMobile(customer.mobile) },
    { label: 'Alternate mobile', value: formatMobile(customer.alternate_mobile) },
    { label: 'Email', value: customer.email ?? '—' },
    { label: 'GSTIN', value: customer.gstin ?? '—' },
    { label: 'PAN', value: customer.pan ?? '—' },
    {
      label: 'Address',
      value:
        [customer.address_line1, customer.address_line2, customer.city, customer.state, customer.pincode]
          .filter(Boolean)
          .join(', ') || '—',
    },
    { label: 'Registered at', value: branch?.name ?? '—' },
    { label: 'Added', value: formatDateTime(customer.created_at) },
    { label: 'Last updated', value: formatDate(customer.updated_at) },
  ];

  return (
    <div>
      <div className="mb-4">
        <Button variant="ghost" size="sm" asChild className="-ml-2 mb-2">
          <Link href="/customers">
            <ArrowLeft aria-hidden />
            All customers
          </Link>
        </Button>

        <div className="flex flex-wrap items-start justify-between gap-3">
          <div>
            <div className="flex items-center gap-2">
              <h1 className="text-xl font-bold tracking-tight text-ink-900">{customer.name}</h1>
              <Badge variant={STATUS_TONE[customer.status] ?? 'neutral'}>{customer.status}</Badge>
              {customer.customer_type === 'BUSINESS' && <Badge variant="info">Business</Badge>}
            </div>
            <p className="mt-0.5 font-mono text-sm text-ink-500">{customer.customer_code}</p>
          </div>

          {canEdit && (
            <Button variant="secondary" asChild>
              <Link href={`/customers/${customer.id}/edit`}>
                <Pencil aria-hidden />
                Edit
              </Link>
            </Button>
          )}
        </div>
      </div>

      <div className="grid gap-4 lg:grid-cols-3">
        <Panel className="lg:col-span-2">
          <PanelHeader>
            <PanelTitle>Details</PanelTitle>
          </PanelHeader>
          <PanelContent>
            <dl className="grid gap-x-8 gap-y-4 sm:grid-cols-2">
              {identity.map((field) => (
                <div key={field.label}>
                  <dt className="text-xs font-medium uppercase tracking-wide text-ink-400">
                    {field.label}
                  </dt>
                  <dd className="mt-0.5 text-sm text-ink-900">{field.value}</dd>
                </div>
              ))}
            </dl>

            {customer.notes && (
              <div className="mt-5 rounded-lg border border-ink-200 bg-ink-50 p-3">
                <p className="text-xs font-medium uppercase tracking-wide text-ink-400">Notes</p>
                <p className="mt-1 whitespace-pre-wrap text-sm text-ink-700">{customer.notes}</p>
              </div>
            )}
          </PanelContent>
        </Panel>

        <Panel>
          <PanelHeader>
            <div>
              <PanelTitle>Customer 360</PanelTitle>
              <p className="text-xs text-ink-500">Fills in as each module is built</p>
            </div>
          </PanelHeader>
          <PanelContent>
            <ul className="space-y-2">
              {RELATED.map((item) => (
                <li
                  key={item.label}
                  className="flex items-start justify-between gap-2 rounded-lg border border-dashed border-ink-200 px-3 py-2"
                >
                  <span className="min-w-0">
                    <span className="block text-sm font-medium text-ink-600">{item.label}</span>
                    <span className="block text-xs text-ink-400">{item.note}</span>
                  </span>
                  <Badge variant="neutral">P{item.phase}</Badge>
                </li>
              ))}
            </ul>
          </PanelContent>
        </Panel>
      </div>
    </div>
  );
}
