import type { Metadata } from 'next';
import Link from 'next/link';
import { notFound } from 'next/navigation';
import { ArrowLeft, Lock } from 'lucide-react';

import { getSale } from '@/server/services/sales/sale-service';
import { requireTenantContext } from '@/server/auth/tenant-context';
import { Panel, PanelContent, PanelHeader, PanelTitle, SolidPanel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { SaleProgress, SaleWorkflow } from '@/components/sales/sale-workflow';
import { formatINR, percentageOf } from '@/lib/money';
import { formatDate, formatMobile, formatPercent } from '@/lib/format';

export const metadata: Metadata = { title: 'Sale' };
export const dynamic = 'force-dynamic';

const STATUS_TONE: Record<string, 'neutral' | 'info' | 'warning' | 'positive' | 'danger' | 'accent'> = {
  DRAFT: 'neutral', SUBMITTED: 'info', ACCOUNTS_VERIFICATION: 'warning',
  APPROVED: 'accent', POSTED: 'positive', DELIVERED: 'positive',
  CANCELLED: 'danger', RETURNED: 'danger',
};

export default async function SaleDetailPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const context = await requireTenantContext();
  const sale = await getSale(id);

  if (!sale) {
    notFound();
  }

  const can = {
    submit: context.permissions.has('sales.submit'),
    verify: context.permissions.has('sales.verify'),
    approve: context.permissions.has('sales.approve'),
    post: context.permissions.has('sales.post'),
    deliver: context.permissions.has('sales.deliver'),
    cancel: context.permissions.has('sales.cancel'),
    create: context.permissions.has('sales.create'),
  };

  // Spec §53: the accounts verification screen shows what the cashier entered
  // beside what the system will post.
  const verifying = sale.status === 'SUBMITTED' || sale.status === 'ACCOUNTS_VERIFICATION';

  return (
    <div>
      <Button variant="ghost" size="sm" asChild className="-ml-2 mb-2">
        <Link href="/sales"><ArrowLeft aria-hidden />Vehicle sales</Link>
      </Button>

      <div className="mb-3 flex flex-wrap items-start justify-between gap-3">
        <div>
          <div className="flex items-center gap-2">
            <h1 className="font-mono text-xl font-bold tracking-tight text-ink-900">{sale.invoiceNumber}</h1>
            <Badge variant={STATUS_TONE[sale.status] ?? 'neutral'}>{sale.status.replace(/_/g, ' ')}</Badge>
            {sale.status === 'POSTED' || sale.status === 'DELIVERED' ? (
              <span className="flex items-center gap-1 text-xs text-ink-500">
                <Lock className="size-3.5" aria-hidden />
                Immutable
              </span>
            ) : null}
          </div>
          <p className="mt-0.5 text-sm text-ink-500">
            {sale.customerName} · {sale.modelLabel} · {sale.branchName}
          </p>
        </div>

        {sale.bookingNumber && (
          <Button variant="secondary" size="sm" asChild>
            <Link href={`/bookings/${sale.bookingId}`}>From booking {sale.bookingNumber}</Link>
          </Button>
        )}
      </div>

      <div className="mb-4">
        <SaleProgress status={sale.status} />
      </div>

      <div className="mb-4">
        <SaleWorkflow saleId={sale.id} status={sale.status} balanceDue={sale.balanceAmount} can={can} />
      </div>

      {verifying && can.verify && (
        <Panel className="mb-4 p-4">
          <div className="flex items-start gap-3">
            <Badge variant="warning">Verification</Badge>
            <p className="text-sm text-ink-600">
              Check the customer, chassis, price version, tax and payment below against the physical
              paperwork. Approving allows posting; posting is what touches the ledger.
            </p>
          </div>
        </Panel>
      )}

      <div className="grid gap-4 lg:grid-cols-3">
        <div className="space-y-4 lg:col-span-2">
          <Panel>
            <PanelHeader><PanelTitle>Invoice lines</PanelTitle></PanelHeader>
            <PanelContent className="px-0 pb-0">
              <SolidPanel className="rounded-none border-x-0 border-b-0">
                <div className="overflow-auto">
                  <table className="w-full border-collapse text-sm">
                    <caption className="sr-only">Invoice lines</caption>
                    <thead>
                      <tr className="bg-ink-50">
                        <th scope="col" className="px-4 py-2.5 text-left text-[11px] font-semibold uppercase tracking-wide text-ink-500">Description</th>
                        <th scope="col" className="px-4 py-2.5 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">Qty</th>
                        <th scope="col" className="px-4 py-2.5 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">Rate</th>
                        <th scope="col" className="px-4 py-2.5 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">Taxable</th>
                        <th scope="col" className="px-4 py-2.5 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">GST</th>
                        {sale.canSeeCost && (
                          <th scope="col" className="px-4 py-2.5 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">Cost</th>
                        )}
                        <th scope="col" className="px-4 py-2.5 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">Total</th>
                      </tr>
                    </thead>
                    <tbody>
                      {sale.lines.map((line) => (
                        <tr key={line.lineNumber} className="border-t border-ink-100">
                          <td className="px-4 py-2">
                            <span className="text-ink-800">{line.description}</span>
                            <span className="ml-2 rounded bg-ink-100 px-1.5 text-[10px] text-ink-500">
                              {line.lineType}
                            </span>
                            {/* Spec §31: the allocation source is visible on the invoice. */}
                            {line.stockSource && (
                              <Badge variant={line.stockSource === 'LOCAL' ? 'positive' : 'info'} className="ml-2">
                                {line.stockSource}
                              </Badge>
                            )}
                          </td>
                          <td className="numeric px-4 py-2">{line.quantity}</td>
                          <td className="numeric px-4 py-2">{formatINR(line.unitRate)}</td>
                          <td className="numeric px-4 py-2">{formatINR(line.taxableValue)}</td>
                          <td className="numeric px-4 py-2">
                            {formatINR((line.cgstAmount + line.sgstAmount + line.igstAmount) as typeof line.cgstAmount)}
                          </td>
                          {sale.canSeeCost && (
                            <td className="numeric px-4 py-2 text-ink-500">
                              {line.costAmount === null ? '—' : formatINR(line.costAmount)}
                            </td>
                          )}
                          <td className="numeric px-4 py-2 font-medium">{formatINR(line.totalAmount)}</td>
                        </tr>
                      ))}
                      {sale.lines.length === 0 && (
                        <tr><td colSpan={7} className="px-4 py-8 text-center text-sm text-ink-400">No lines on this invoice.</td></tr>
                      )}
                    </tbody>
                  </table>
                </div>
              </SolidPanel>
            </PanelContent>
          </Panel>

          <Panel>
            <PanelHeader><PanelTitle>Receipts</PanelTitle></PanelHeader>
            <PanelContent>
              {sale.payments.length === 0 ? (
                <p className="text-sm text-ink-400">No payments recorded.</p>
              ) : (
                <ul className="space-y-2">
                  {sale.payments.map((p) => (
                    <li key={p.id} className="flex items-center justify-between rounded-lg border border-ink-200 px-3 py-2">
                      <span className="min-w-0">
                        <span className="block font-mono text-xs text-ink-700">{p.receiptNumber}</span>
                        <span className="block text-xs text-ink-400">{formatDate(p.paymentDate)} · {p.mode}</span>
                      </span>
                      <span className="flex items-center gap-3">
                        <span className="numeric text-sm font-medium text-ink-900">{formatINR(p.amount)}</span>
                        {p.journalEntryId && (
                          <Link href={`/accounting/journals/${p.journalEntryId}`} className="text-xs text-brand-600 hover:underline">
                            Entry
                          </Link>
                        )}
                      </span>
                    </li>
                  ))}
                </ul>
              )}
            </PanelContent>
          </Panel>
        </div>

        <div className="space-y-4">
          <Panel>
            <PanelHeader><PanelTitle>Summary</PanelTitle></PanelHeader>
            <PanelContent>
              <dl className="space-y-2.5">
                <Row label="Taxable value" value={formatINR(sale.taxableValue)} />
                {sale.cgstAmount > 0 && <Row label="CGST" value={formatINR(sale.cgstAmount)} />}
                {sale.sgstAmount > 0 && <Row label="SGST" value={formatINR(sale.sgstAmount)} />}
                {sale.igstAmount > 0 && <Row label="IGST" value={formatINR(sale.igstAmount)} />}
                <div className="border-t border-ink-200 pt-2.5">
                  <Row label="Invoice total" value={formatINR(sale.totalAmount)} strong />
                </div>
                <Row label="Received" value={formatINR(sale.paidAmount)} tone="positive" />
                <Row label="Finance" value={formatINR(sale.financeAmount)} tone="positive" />
                <div className="border-t border-ink-200 pt-2.5">
                  <Row label="Balance" value={formatINR(sale.balanceAmount)}
                    tone={sale.balanceAmount > 0 ? 'warning' : 'positive'} strong />
                </div>
              </dl>
            </PanelContent>
          </Panel>

          {/* Restricted: only built when the session holds sales.view_cost. */}
          {sale.canSeeCost && sale.totalCost !== null && sale.margin !== null && (
            <Panel>
              <PanelHeader>
                <div className="flex items-center gap-2">
                  <PanelTitle>Margin</PanelTitle>
                  <Badge variant="warning">Restricted</Badge>
                </div>
              </PanelHeader>
              <PanelContent>
                <dl className="space-y-2.5">
                  <Row label="Cost of goods" value={formatINR(sale.totalCost)} />
                  <Row label="Gross margin" value={formatINR(sale.margin)}
                    tone={sale.margin >= 0 ? 'positive' : 'warning'} strong />
                  <Row label="Margin %" value={formatPercent(percentageOf(sale.margin, sale.taxableValue), 2)} />
                </dl>
              </PanelContent>
            </Panel>
          )}

          <Panel>
            <PanelHeader><PanelTitle>Details</PanelTitle></PanelHeader>
            <PanelContent>
              <dl className="space-y-3">
                <Detail label="Customer" value={`${sale.customerName} (${sale.customerCode})`} />
                <Detail label="Mobile" value={formatMobile(sale.customerMobile)} />
                {sale.customerGstin && <Detail label="GSTIN" value={sale.customerGstin} />}
                <Detail label="Chassis" value={sale.chassisNo} mono />
                <Detail label="Engine" value={sale.engineNo} mono />
                <Detail label="Invoice date" value={formatDate(sale.invoiceDate)} />
                <Detail
                  label="Price version"
                  value={sale.priceVersionNumber ? `v${sale.priceVersionNumber}` : 'Not recorded'}
                />
              </dl>

              {sale.journalEntryId && (
                <Button variant="secondary" size="sm" asChild className="mt-4 w-full">
                  <Link href={`/accounting/journals/${sale.journalEntryId}`}>View journal entry</Link>
                </Button>
              )}
            </PanelContent>
          </Panel>
        </div>
      </div>
    </div>
  );
}

function Row({
  label, value, tone, strong,
}: {
  readonly label: string; readonly value: string;
  readonly tone?: 'positive' | 'warning'; readonly strong?: boolean;
}) {
  const colour = tone === 'positive' ? 'text-positive-700' : tone === 'warning' ? 'text-warning-700' : 'text-ink-900';
  return (
    <div className="flex items-center justify-between">
      <dt className="text-sm text-ink-600">{label}</dt>
      <dd className={`numeric ${strong ? 'text-base font-bold' : 'text-sm'} ${colour}`}>{value}</dd>
    </div>
  );
}

function Detail({ label, value, mono }: { readonly label: string; readonly value: string; readonly mono?: boolean }) {
  return (
    <div>
      <dt className="text-xs font-medium uppercase tracking-wide text-ink-400">{label}</dt>
      <dd className={`mt-0.5 text-sm text-ink-900 ${mono ? 'font-mono text-xs' : ''}`}>{value}</dd>
    </div>
  );
}
