import Link from 'next/link';
import type { Metadata } from 'next';

import { getDayBook } from '@/server/services/accounting/day-book-service';
import { requireTenantContext } from '@/server/auth/tenant-context';
import { PageHeader } from '@/components/data-table/data-table';
import { SolidPanel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { formatDate, formatTime } from '@/lib/format';

export const metadata: Metadata = { title: 'Day Book' };
export const dynamic = 'force-dynamic';

const inr = new Intl.NumberFormat('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const money = (n: number) => (n ? inr.format(n) : '—');

const TYPE_LABEL: Record<string, string> = {
  CASH_BOOK: 'Cash',
  BANK_BOOK: 'Bank',
  CONTRA: 'Contra',
  MANUAL_JOURNAL: 'Journal',
  SALE: 'Sale',
  SERVICE_INVOICE: 'Service',
  BOOKING: 'Booking',
  OPENING_BALANCE: 'Opening',
  PURCHASE_BILL: 'Purchase',
};

/**
 * The day book — BUSY's Display → Day Book (F32). Every voucher posted on the
 * day with its lines, the day's totals, and each branch's cash position from
 * the cash book. Each voucher opens its journal.
 */
export default async function DayBookPage({
  searchParams,
}: {
  searchParams: Promise<{ date?: string; branch?: string }>;
}) {
  const context = await requireTenantContext();
  const params = await searchParams;
  const date = /^\d{4}-\d{2}-\d{2}$/.test(params.date ?? '') ? params.date! : new Date().toISOString().slice(0, 10);
  const branchId = params.branch && params.branch !== 'all' ? params.branch : null;

  const { vouchers, cash } = await getDayBook(date, branchId);
  const totalDebit = vouchers.reduce((s, v) => s + v.lines.reduce((t, l) => t + l.debit, 0), 0);
  const totalCredit = vouchers.reduce((s, v) => s + v.lines.reduce((t, l) => t + l.credit, 0), 0);

  const prev = new Date(`${date}T00:00:00Z`);
  prev.setUTCDate(prev.getUTCDate() - 1);
  const next = new Date(`${date}T00:00:00Z`);
  next.setUTCDate(next.getUTCDate() + 1);
  const link = (d: Date) => `/accounting/day-book?date=${d.toISOString().slice(0, 10)}${branchId ? `&branch=${branchId}` : ''}`;

  return (
    <div className="space-y-4">
      <PageHeader
        title="Day Book"
        description={`${formatDate(date)} — ${vouchers.length} voucher${vouchers.length === 1 ? '' : 's'}`}
        action={
          <div className="flex items-center gap-2 text-sm">
            <Link href={link(prev)} className="text-brand-700 hover:underline">← Previous day</Link>
            <Link href={link(next)} className="text-brand-700 hover:underline">Next day →</Link>
          </div>
        }
      />

      <form className="flex flex-wrap items-center gap-2">
        <Input type="date" name="date" defaultValue={date} className="w-44" aria-label="Date" />
        {context.accessibleBranches.length > 1 && (
          <select name="branch" defaultValue={branchId ?? 'all'} className="field h-10 px-3 text-sm" aria-label="Branch">
            {context.hasAllBranchAccess && <option value="all">All branches</option>}
            {context.accessibleBranches.map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}
          </select>
        )}
        <Button type="submit" variant="secondary" size="sm">Show</Button>
      </form>

      {cash.length > 0 && (
        <SolidPanel className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead>
              <tr className="text-[11px] uppercase tracking-wide text-ink-500">
                <th className="px-4 py-2 text-left font-semibold">Cash — branch</th>
                <th className="px-4 py-2 text-right font-semibold">Opening</th>
                <th className="px-4 py-2 text-right font-semibold">Receipts</th>
                <th className="px-4 py-2 text-right font-semibold">Payments</th>
                <th className="px-4 py-2 text-right font-semibold">Closing</th>
                <th className="px-4 py-2" />
              </tr>
            </thead>
            <tbody>
              {cash.map((c) => (
                <tr key={c.branchName} className="border-t border-ink-100">
                  <td className="px-4 py-2 text-ink-800">{c.branchName}</td>
                  <td className="numeric px-4 py-2">{money(c.opening)}</td>
                  <td className="numeric px-4 py-2">{money(c.receipts)}</td>
                  <td className="numeric px-4 py-2">{money(c.payments)}</td>
                  <td className="numeric px-4 py-2 font-semibold">{money(c.closing)}</td>
                  <td className="px-4 py-2 text-right"><Badge variant={c.status === 'CLOSED' ? 'neutral' : 'info'}>{c.status.toLowerCase()}</Badge></td>
                </tr>
              ))}
            </tbody>
          </table>
        </SolidPanel>
      )}

      <SolidPanel className="overflow-hidden">
        <div className="table-sticky overflow-auto" style={{ maxHeight: '44rem' }}>
          <table className="w-full border-collapse text-sm">
            <thead>
              <tr className="text-[11px] uppercase tracking-wide text-ink-500">
                <th className="px-4 py-2.5 text-left font-semibold">Voucher</th>
                <th className="px-4 py-2.5 text-left font-semibold">Account / party</th>
                <th className="px-4 py-2.5 text-right font-semibold">Debit</th>
                <th className="px-4 py-2.5 text-right font-semibold">Credit</th>
              </tr>
            </thead>
            {vouchers.length === 0 ? (
              <tbody>
                <tr><td colSpan={4} className="px-4 py-12 text-center text-sm text-ink-400">Nothing was posted on {formatDate(date)}.</td></tr>
              </tbody>
            ) : (
              vouchers.map((v) => (
                <tbody key={v.entryId} className="border-t-2 border-ink-100">
                  <tr className="bg-ink-50/60">
                    <td className="px-4 py-2" colSpan={4}>
                      <div className="flex flex-wrap items-center gap-2">
                        <span className="text-xs text-ink-500">{formatTime(v.time)}</span>
                        <Badge variant="neutral">{TYPE_LABEL[v.documentType ?? ''] ?? (v.documentType ?? 'Journal').toLowerCase().replace(/_/g, ' ')}</Badge>
                        <Link href={`/accounting/journals/${v.entryId}`} className="font-mono text-xs text-brand-700 hover:underline">
                          {v.documentRef}
                        </Link>
                        {v.documentRef !== v.entryNumber && <span className="font-mono text-[11px] text-ink-400">{v.entryNumber}</span>}
                        {v.status === 'REVERSED' && <Badge variant="warning">reversed</Badge>}
                        {v.branchName && <span className="text-[11px] text-ink-400">{v.branchName}</span>}
                        {v.narration && <span className="text-xs text-ink-600">— {v.narration}</span>}
                      </div>
                    </td>
                  </tr>
                  {v.lines.map((l) => (
                    <tr key={l.lineNumber}>
                      <td className="px-4 py-1.5" />
                      <td className="px-4 py-1.5 text-ink-800">
                        <span className="font-mono text-[11px] text-ink-400">{l.accountCode}</span> {l.accountName}
                        {l.partyName && <span className="text-ink-500"> · {l.partyName}</span>}
                        {l.narration && l.narration !== v.narration && <span className="block text-[11px] text-ink-400">{l.narration}</span>}
                      </td>
                      <td className="numeric px-4 py-1.5">{money(l.debit)}</td>
                      <td className="numeric px-4 py-1.5">{money(l.credit)}</td>
                    </tr>
                  ))}
                </tbody>
              ))
            )}
            <tfoot>
              <tr className="border-t-2 border-ink-300 bg-ink-50 font-semibold">
                <td colSpan={2} className="px-4 py-3 text-ink-900">Day total</td>
                <td className="numeric px-4 py-3">{money(totalDebit)}</td>
                <td className="numeric px-4 py-3">{money(totalCredit)}</td>
              </tr>
            </tfoot>
          </table>
        </div>
      </SolidPanel>
    </div>
  );
}
