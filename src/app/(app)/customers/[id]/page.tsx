import type { Metadata } from 'next';
import Link from 'next/link';
import { notFound } from 'next/navigation';
import { ArrowLeft, BookOpen, FileText, Pencil } from 'lucide-react';

import { getCustomer, getCustomer360 } from '@/server/services/customers/customer-service';
import { requireTenantContext } from '@/server/auth/tenant-context';
import { NotFoundError } from '@/server/errors';
import { Panel, PanelContent, PanelHeader, PanelTitle } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { formatDate, formatDateTime, formatMobile } from '@/lib/format';
import { formatINR, type Paise } from '@/lib/money';

export const metadata: Metadata = { title: 'Customer' };
export const dynamic = 'force-dynamic';

const STATUS_TONE: Record<string, 'positive' | 'neutral' | 'danger'> = {
  ACTIVE: 'positive',
  INACTIVE: 'neutral',
  BLOCKED: 'danger',
};



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

  const summary = await getCustomer360(customer.id);

  const canEdit = context.permissions.has('customers.edit');
  // Tallying a customer's account is the accountant's job (spec §6).
  const canJournal = context.permissions.has('accounting.journals.post');
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

          <div className="flex flex-wrap gap-2">
            {canJournal && (
              <Button asChild>
                <Link href={`/customers/${customer.id}/journal`}>
                  <BookOpen aria-hidden />
                  Journal entry
                </Link>
              </Button>
            )}
            <Button variant="secondary" asChild>
              <Link href={`/customers/ledger?customer=${customer.id}`}>
                <FileText aria-hidden />
                Ledger
              </Link>
            </Button>
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
              <p className="text-xs text-ink-500">
                {summary.lastActivity
                  ? `Last activity ${formatDate(summary.lastActivity)}`
                  : 'No transactions yet'}
              </p>
            </div>
          </PanelHeader>
          <PanelContent>
            <ul className="space-y-1.5">
              <Related
                label="Bookings"
                count={summary.bookingCount}
                value={summary.bookingAdvance}
                valueLabel="advance held"
                href={`/bookings?q=${encodeURIComponent(customer.customer_code)}`}
              />
              <Related
                label="Vehicle sales"
                count={summary.saleCount}
                value={summary.saleValue}
                valueLabel="invoiced"
                href={`/sales?q=${encodeURIComponent(customer.customer_code)}`}
              />
              <Related
                label="Payments"
                count={null}
                value={summary.paidAmount}
                valueLabel="received"
                href={`/customers/ledger?customer=${customer.id}`}
              />
              <Related
                label="Service"
                count={summary.serviceCount}
                value={summary.serviceValue}
                valueLabel="billed"
                href={`/customers/service?customer=${customer.id}`}
              />
              <Related
                label="Vehicles"
                count={summary.vehicleCount}
                value={null}
                href={`/customers/vehicles?customer=${customer.id}`}
              />
            </ul>

            {/* The one figure that is a balance rather than a total, so it is
                separated from the list and takes its colour from its sign. */}
            <div className="mt-3 flex items-center justify-between rounded-lg border border-ink-200 bg-ink-50 px-3 py-2">
              <span className="text-sm font-medium text-ink-700">Outstanding</span>
              <span
                className={`numeric text-sm font-semibold ${
                  summary.outstanding > 0 ? 'text-warning-700' : 'text-ink-700'
                }`}
              >
                {formatINR(summary.outstanding)}
              </span>
            </div>
            <p className="mt-1.5 text-[11px] text-ink-400">
              From the customer&rsquo;s ledger account, so it always agrees with the ledger screen.
            </p>
          </PanelContent>
        </Panel>
      </div>
    </div>
  );
}

/**
 * One line of the Customer 360 panel.
 *
 * Every row links through to the screen that holds the detail — spec §43 asks
 * that every number be drillable, and a summary you cannot open is a claim
 * rather than a record.
 */
function Related({
  label,
  count,
  value,
  valueLabel,
  href,
}: {
  readonly label: string;
  readonly count: number | null;
  readonly value: Paise | null;
  readonly valueLabel?: string;
  readonly href: string;
}) {
  return (
    <li>
      <Link
        href={href}
        className="flex items-center justify-between gap-2 rounded-lg border border-ink-200 px-3 py-2 transition-colors hover:border-brand-300 hover:bg-brand-50/50"
      >
        <span className="min-w-0">
          <span className="block text-sm font-medium text-ink-700">{label}</span>
          {value !== null && (
            <span className="block text-xs text-ink-500">
              <span className="numeric">{formatINR(value)}</span>
              {valueLabel ? ` ${valueLabel}` : ''}
            </span>
          )}
        </span>
        {count !== null && <Badge variant={count > 0 ? 'info' : 'neutral'}>{count}</Badge>}
      </Link>
    </li>
  );
}
