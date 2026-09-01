import type { Metadata } from 'next';
import Link from 'next/link';
import { notFound } from 'next/navigation';
import { ArrowLeft, ArrowRight, Receipt } from 'lucide-react';

import { getBooking } from '@/server/services/sales/booking-service';
import { requireTenantContext } from '@/server/auth/tenant-context';
import { Panel, PanelContent, PanelHeader, PanelTitle, SolidPanel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { CancelBooking } from '@/components/sales/booking-actions';
import { formatINR, subtract } from '@/lib/money';
import { formatDate, formatMobile } from '@/lib/format';

export const metadata: Metadata = { title: 'Booking' };
export const dynamic = 'force-dynamic';

const STATUS_TONE: Record<string, 'positive' | 'info' | 'neutral' | 'danger'> = {
  OPEN: 'positive',
  CONVERTED: 'info',
  CANCELLED: 'danger',
  EXPIRED: 'neutral',
};

export default async function BookingDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const context = await requireTenantContext();
  const detail = await getBooking(id);

  if (!detail) {
    notFound();
  }

  const { booking, customerName, customerCode, customerMobile, modelLabel, branchName, payments } = detail;
  const balance = subtract(booking.bookingAmount, booking.receivedAmount);
  const canConvert = context.permissions.has('bookings.convert') && booking.status === 'OPEN';

  return (
    <div>
      <Button variant="ghost" size="sm" asChild className="-ml-2 mb-2">
        <Link href="/bookings"><ArrowLeft aria-hidden />Bookings</Link>
      </Button>

      <div className="mb-4 flex flex-wrap items-start justify-between gap-3">
        <div>
          <div className="flex items-center gap-2">
            <h1 className="font-mono text-xl font-bold tracking-tight text-ink-900">{booking.bookingNumber}</h1>
            <Badge variant={STATUS_TONE[booking.status] ?? 'neutral'}>{booking.status}</Badge>
          </div>
          <p className="mt-0.5 text-sm text-ink-500">
            {customerName} · {modelLabel} · {branchName}
          </p>
        </div>

        <div className="flex gap-2">
          <CancelBooking id={booking.id} canCancel={context.permissions.has('bookings.cancel') && booking.status === 'OPEN'} />
          {canConvert && (
            <Button asChild>
              <Link href={`/sales/new?booking=${booking.id}`}>
                Convert to sale
                <ArrowRight aria-hidden />
              </Link>
            </Button>
          )}
          {booking.convertedSaleId && (
            <Button variant="secondary" asChild>
              <Link href={`/sales/${booking.convertedSaleId}`}>View the sale</Link>
            </Button>
          )}
        </div>
      </div>

      {booking.status === 'CANCELLED' && booking.cancelledReason && (
        <Panel className="mb-4 flex items-start gap-3 p-4">
          <Badge variant="danger">Cancelled</Badge>
          <p className="text-sm text-ink-700">{booking.cancelledReason}</p>
        </Panel>
      )}

      <div className="grid gap-4 lg:grid-cols-3">
        <Panel className="lg:col-span-2">
          <PanelHeader><PanelTitle>Booking</PanelTitle></PanelHeader>
          <PanelContent>
            <dl className="grid gap-x-8 gap-y-4 sm:grid-cols-2">
              <Detail label="Customer" value={`${customerName} (${customerCode})`} />
              <Detail label="Mobile" value={formatMobile(customerMobile)} />
              <Detail label="Model" value={modelLabel} />
              <Detail label="Branch" value={branchName} />
              <Detail label="Booking date" value={formatDate(booking.bookingDate)} />
              <Detail label="Expected delivery" value={booking.expectedDelivery ? formatDate(booking.expectedDelivery) : '—'} />
            </dl>

            {booking.notes && (
              <div className="mt-5 rounded-lg border border-ink-200 bg-ink-50 p-3">
                <p className="text-xs font-medium uppercase tracking-wide text-ink-400">Notes</p>
                <p className="mt-1 whitespace-pre-wrap text-sm text-ink-700">{booking.notes}</p>
              </div>
            )}
          </PanelContent>
        </Panel>

        <Panel>
          <PanelHeader><PanelTitle>Amounts</PanelTitle></PanelHeader>
          <PanelContent>
            <dl className="space-y-3">
              <Amount label="Booking value" value={formatINR(booking.bookingAmount)} />
              <Amount label="Advance received" value={formatINR(booking.receivedAmount)} tone="positive" />
              <div className="border-t border-ink-200 pt-3">
                <Amount label="Balance" value={formatINR(balance)} tone={balance > 0 ? 'warning' : 'positive'} strong />
              </div>
            </dl>
            <p className="mt-4 text-xs text-ink-500">
              The advance sits in Customer Advances. It becomes revenue only when the sale is posted.
            </p>
          </PanelContent>
        </Panel>
      </div>

      <div className="mt-4">
        <h2 className="mb-2 flex items-center gap-2 text-sm font-semibold text-ink-900">
          <Receipt className="size-4 text-ink-400" aria-hidden />
          Receipts
        </h2>
        <SolidPanel className="overflow-hidden">
          <table className="w-full border-collapse text-sm">
            <caption className="sr-only">Booking receipts</caption>
            <thead>
              <tr className="bg-ink-50">
                {['Receipt', 'Date', 'Mode', 'Reference', 'Amount', 'Journal'].map((h) => (
                  <th key={h} scope="col" className="px-4 py-2.5 text-left text-[11px] font-semibold uppercase tracking-wide text-ink-500">
                    {h}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {payments.length === 0 ? (
                <tr><td colSpan={6} className="px-4 py-8 text-center text-sm text-ink-400">No receipts recorded.</td></tr>
              ) : (
                payments.map((p) => (
                  <tr key={p.id} className="border-t border-ink-100">
                    <td className="px-4 py-2 font-mono text-xs text-ink-700">{p.receiptNumber}</td>
                    <td className="px-4 py-2">{formatDate(p.paymentDate)}</td>
                    <td className="px-4 py-2"><Badge variant="info">{p.mode}</Badge></td>
                    <td className="px-4 py-2 text-ink-600">{p.reference ?? '—'}</td>
                    <td className="numeric px-4 py-2">{formatINR(p.amount)}</td>
                    <td className="px-4 py-2">
                      {p.journalEntryId ? (
                        <Link href={`/accounting/journals/${p.journalEntryId}`} className="text-xs text-brand-600 hover:underline">
                          View entry
                        </Link>
                      ) : (
                        <span className="text-xs text-ink-400">—</span>
                      )}
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </SolidPanel>
      </div>
    </div>
  );
}

function Detail({ label, value }: { readonly label: string; readonly value: string }) {
  return (
    <div>
      <dt className="text-xs font-medium uppercase tracking-wide text-ink-400">{label}</dt>
      <dd className="mt-0.5 text-sm text-ink-900">{value}</dd>
    </div>
  );
}

function Amount({
  label, value, tone, strong,
}: {
  readonly label: string; readonly value: string;
  readonly tone?: 'positive' | 'warning'; readonly strong?: boolean;
}) {
  const colour = tone === 'positive' ? 'text-positive-700' : tone === 'warning' ? 'text-warning-700' : 'text-ink-900';
  return (
    <div className="flex items-center justify-between">
      <dt className="text-sm text-ink-600">{label}</dt>
      <dd className={`numeric ${strong ? 'text-base font-bold' : 'text-sm font-medium'} ${colour}`}>{value}</dd>
    </div>
  );
}
