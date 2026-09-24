import Link from 'next/link';
import type { Metadata } from 'next';

import {
  getFilingGstins, getGstr2bImports, getGstr2bReconciliation, getItcClaimable,
} from '@/server/services/gst/gst-returns-service';
import { GSTR2B_TEMPLATE } from '@/server/services/gst/gstr2b-import';
import { requirePermission } from '@/server/auth/tenant-context';
import { PageHeader } from '@/components/data-table/data-table';
import { Panel, PanelContent, PanelHeader, PanelTitle, SolidPanel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Gstr2bImport } from '@/components/gst/gstr2b-import';
import { ReturnPeriodPicker, resolveReturnPeriod } from '@/components/gst/return-period-picker';
import { add, formatINR } from '@/lib/money';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'GSTR-2B' };
export const dynamic = 'force-dynamic';

const TONE: Record<string, 'positive' | 'warning' | 'danger' | 'info' | 'neutral'> = {
  MATCHED: 'positive', VALUE_MISMATCH: 'warning', NOT_IN_BOOKS: 'danger', NOT_IN_2B: 'danger', NOT_CLAIMABLE: 'neutral',
};
const LABEL: Record<string, string> = {
  MATCHED: 'Matched', VALUE_MISMATCH: 'Value differs', NOT_IN_BOOKS: 'Not in books',
  NOT_IN_2B: 'Not in 2B', NOT_CLAIMABLE: 'Not claimable',
};

/**
 * GSTR-2B against the books — checklist §08. Credit is claimable only once the
 * supplier's invoice is in 2B (rule 36(4)), at the lower of 2B and the books;
 * a purchase the books mark blocked or personal is never claimed, 2B or not.
 */
export default async function Gstr2bPage({
  searchParams,
}: {
  searchParams: Promise<{ gstin?: string; period?: string }>;
}) {
  const context = await requirePermission('gst.reports.view');
  const params = await searchParams;
  const gstins = await getFilingGstins();
  const gstin = gstins.includes(params.gstin ?? '') ? params.gstin! : gstins[0];
  const { month, period } = resolveReturnPeriod(params.period);
  const th = 'px-4 py-2.5 text-[11px] font-semibold uppercase tracking-wide text-ink-500';

  if (!gstin) {
    return (
      <div className="space-y-5">
        <PageHeader title="GSTR-2B" description="Supplier invoices as the portal sees them, matched to your bills." />
        <Panel className="p-6 text-sm text-ink-600">Record a GSTIN on the dealer or a branch first (Administration → Branches).</Panel>
      </div>
    );
  }

  const imports = await getGstr2bImports(gstin);
  const current = imports.find((i) => i.period === period);
  const [recon, claims] = await Promise.all([
    current ? getGstr2bReconciliation(current.id) : Promise.resolve([]),
    getItcClaimable(gstin, period),
  ]);
  const claimable = add(...claims.filter((c) => c.claimable).map((c) => c.tax));
  const waiting = add(...claims.filter((c) => !c.claimable).map((c) => c.tax));
  const canImport = context.permissions.has('gst.returns.prepare');
  const counts = recon.reduce<Record<string, number>>((acc, r) => ({ ...acc, [r.status]: (acc[r.status] ?? 0) + 1 }), {});

  return (
    <div className="space-y-5">
      <PageHeader title="GSTR-2B" description="Supplier invoices as the portal sees them, matched to your bills." />
      <ReturnPeriodPicker gstins={gstins} gstin={gstin} month={month} />

      <div className="grid gap-3 sm:grid-cols-3">
        <Panel className="p-4">
          <p className="text-xs text-ink-500">2B for {formatDate(period).slice(3)}</p>
          <p className="mt-1 text-sm font-semibold text-ink-900">
            {current ? `${current.lineCount} lines · imported ${formatDate(current.importedAt.slice(0, 10))}` : 'Not imported'}
          </p>
        </Panel>
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Credit claimable now</p>
          <p className="numeric mt-1 text-xl font-semibold text-positive-700">{formatINR(claimable)}</p>
        </Panel>
        <Panel className="p-4">
          <p className="text-xs text-ink-500">Credit waiting for 2B</p>
          <p className="numeric mt-1 text-xl font-semibold text-warning-700">{formatINR(waiting)}</p>
        </Panel>
      </div>

      {canImport && (
        <Panel>
          <PanelHeader><PanelTitle>{current ? 'Re-import' : 'Import'} GSTR-2B for this month</PanelTitle></PanelHeader>
          <PanelContent><Gstr2bImport gstin={gstin} period={period} template={GSTR2B_TEMPLATE} /></PanelContent>
        </Panel>
      )}

      {current && (
        <SolidPanel className="overflow-hidden">
          <div className="flex flex-wrap items-center gap-2 border-b border-ink-100 px-4 py-3">
            <h2 className="mr-2 text-sm font-semibold text-ink-900">Matching</h2>
            {Object.entries(counts).map(([status, count]) => (
              <Badge key={status} variant={TONE[status] ?? 'neutral'}>{LABEL[status] ?? status}: {count}</Badge>
            ))}
          </div>
          <div className="table-sticky overflow-auto" style={{ maxHeight: '36rem' }}>
            <table className="w-full border-collapse text-sm">
              <thead><tr>
                <th className={`${th} text-left`}>Status</th><th className={`${th} text-left`}>Supplier</th>
                <th className={`${th} text-left`}>Document</th><th className={`${th} text-right`}>Tax in 2B</th>
                <th className={`${th} text-right`}>Tax in books</th><th className={`${th} text-right`}>Difference</th>
              </tr></thead>
              <tbody>
                {recon.map((r) => (
                  <tr key={r.key} className="border-t border-ink-100">
                    <td className="px-4 py-2"><Badge variant={TONE[r.status] ?? 'neutral'}>{LABEL[r.status] ?? r.status}</Badge></td>
                    <td className="px-4 py-2">{r.supplierName ?? '—'}<span className="block font-mono text-[11px] text-ink-400">{r.supplierGstin}</span></td>
                    <td className="px-4 py-2">
                      {r.billId ? <Link href={`/purchases/${r.billId}`} className="font-mono text-xs text-brand-700 hover:underline">{r.documentNumber}</Link>
                        : <span className="font-mono text-xs">{r.documentNumber}</span>}
                      <span className="block text-[11px] text-ink-400">{r.documentDate ? formatDate(r.documentDate) : ''}</span>
                    </td>
                    <td className="numeric px-4 py-2">{r.tax2b === null ? '—' : formatINR(r.tax2b)}</td>
                    <td className="numeric px-4 py-2">{r.taxBooks === null ? '—' : formatINR(r.taxBooks)}</td>
                    <td className={`numeric px-4 py-2 ${r.difference !== 0 ? 'font-semibold text-warning-700' : 'text-ink-400'}`}>{formatINR(r.difference)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </SolidPanel>
      )}

      <SolidPanel className="overflow-hidden">
        <div className="border-b border-ink-100 px-4 py-3">
          <h2 className="text-sm font-semibold text-ink-900">Credit open to claim up to this month</h2>
          <p className="text-xs text-ink-500">What the next GSTR-3B may claim, and what must wait. Credit already claimed in a filed 3B is not shown.</p>
        </div>
        <table className="w-full border-collapse text-sm">
          <thead><tr>
            <th className={`${th} text-left`}>Document</th><th className={`${th} text-left`}>Supplier</th>
            <th className={`${th} text-left`}>Basis</th><th className={`${th} text-right`}>Credit</th>
          </tr></thead>
          <tbody>
            {claims.length === 0 ? (
              <tr><td colSpan={4} className="px-4 py-8 text-center text-ink-400">No open credit.</td></tr>
            ) : claims.map((c) => (
              <tr key={c.key} className="border-t border-ink-100">
                <td className="px-4 py-2 font-mono text-xs">{c.documentNumber}<span className="block font-sans text-[11px] text-ink-400">{formatDate(c.documentDate)} · {c.kind.replace('_', ' ').toLowerCase()}</span></td>
                <td className="px-4 py-2">{c.supplier}</td>
                <td className="px-4 py-2"><Badge variant={c.claimable ? 'positive' : 'warning'}>{c.claimable ? 'Claimable' : 'Waiting'}</Badge> <span className="text-xs text-ink-500">{c.reason}</span></td>
                <td className="numeric px-4 py-2 font-medium">{formatINR(c.tax)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </SolidPanel>
    </div>
  );
}
