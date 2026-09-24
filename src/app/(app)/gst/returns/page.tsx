import Link from 'next/link';
import type { Metadata } from 'next';

import {
  getBankAccountOptions, getCrossChecks, getFilingGstins, getGstr1Amendments, getGstr3bSetoff,
  getGstr3bWorking, getGstReturns, type GstReturnRow,
} from '@/server/services/gst/gst-returns-service';
import {
  postSetoffAction, prepareReturnAction, recordFilingAction, signOffReturnAction,
} from '@/server/services/gst/gst-returns-actions';
import { requirePermission } from '@/server/auth/tenant-context';
import { PageHeader } from '@/components/data-table/data-table';
import { Panel, PanelContent, PanelHeader, PanelTitle, SolidPanel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { ActionForm } from '@/components/forms/action-form';
import { AttachmentsPanel } from '@/components/attachments/attachments-panel';
import { ReturnPeriodPicker, resolveReturnPeriod } from '@/components/gst/return-period-picker';
import { add, formatINR, fromDb } from '@/lib/money';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'GST Returns' };
export const dynamic = 'force-dynamic';

const th = 'px-4 py-2.5 text-[11px] font-semibold uppercase tracking-wide text-ink-500';
const STATUS_TONE: Record<string, 'positive' | 'warning' | 'danger' | 'neutral' | 'info'> = {
  OK: 'positive', DIFFERENCE: 'danger', PENDING: 'neutral',
  PREPARED: 'info', SIGNED_OFF: 'warning', FILED: 'positive',
};

type Totals = { taxable?: string; igst?: string; cgst?: string; sgst?: string };

/**
 * GSTR-1 and GSTR-3B for one GSTIN and month — checklist §09. The system's
 * figures, the checks between the returns and the ledger, and the filing
 * record: prepared by one person, signed off by another, filed with its ARN
 * and challan, the acknowledgement attached, the set-off posted.
 */
export default async function GstReturnsPage({
  searchParams,
}: {
  searchParams: Promise<{ gstin?: string; period?: string }>;
}) {
  const context = await requirePermission('gst.reports.view');
  const params = await searchParams;
  const gstins = await getFilingGstins();
  const gstin = gstins.includes(params.gstin ?? '') ? params.gstin! : gstins[0];
  const { month, period } = resolveReturnPeriod(params.period);

  if (!gstin) {
    return (
      <div className="space-y-5">
        <PageHeader title="GST Returns" description="GSTR-1 and GSTR-3B, checked against each other and the books." />
        <Panel className="p-6 text-sm text-ink-600">Record a GSTIN on the dealer or a branch first (Administration → Branches).</Panel>
      </div>
    );
  }

  const [checks, working, setoff, returns, amendments, banks] = await Promise.all([
    getCrossChecks(gstin, period), getGstr3bWorking(gstin, period), getGstr3bSetoff(gstin, period),
    getGstReturns(gstin, period), getGstr1Amendments(gstin, period), getBankAccountOptions(),
  ]);
  const r1 = returns.find((r) => r.returnType === 'GSTR1');
  const r3 = returns.find((r) => r.returnType === 'GSTR3B');
  const canPrepare = context.permissions.has('gst.returns.prepare');
  const canFile = context.permissions.has('gst.returns.file');
  const differences = checks.filter((c) => c.status === 'DIFFERENCE').length;

  return (
    <div className="space-y-5">
      <PageHeader title="GST Returns" description="GSTR-1 and GSTR-3B, checked against each other and the books."
        action={<Link href={`/gst/gstr-2b?gstin=${gstin}&period=${month}`} className="text-sm text-brand-700 hover:underline">GSTR-2B matching →</Link>} />
      <ReturnPeriodPicker gstins={gstins} gstin={gstin} month={month} />

      <SolidPanel className="overflow-hidden">
        <div className="flex items-center gap-2 border-b border-ink-100 px-4 py-3">
          <h2 className="text-sm font-semibold text-ink-900">Cross-checks</h2>
          {differences > 0
            ? <Badge variant="danger">{differences} difference{differences === 1 ? '' : 's'}</Badge>
            : <Badge variant="positive">No differences</Badge>}
        </div>
        <table className="w-full border-collapse text-sm">
          <thead><tr>
            <th className={`${th} text-left`}>Check</th><th className={`${th} text-right`}>One side</th>
            <th className={`${th} text-right`}>Other side</th><th className={`${th} text-right`}>Difference</th>
            <th className={`${th} text-left`}>Result</th>
          </tr></thead>
          <tbody>
            {checks.map((c) => (
              <tr key={c.code} className="border-t border-ink-100">
                <td className="px-4 py-2 text-ink-800">{c.description}</td>
                <td className="numeric px-4 py-2">{c.left === null ? '—' : formatINR(c.left)}<span className="block text-[11px] text-ink-400">{c.leftLabel}</span></td>
                <td className="numeric px-4 py-2">{c.right === null ? '—' : formatINR(c.right)}<span className="block text-[11px] text-ink-400">{c.rightLabel}</span></td>
                <td className={`numeric px-4 py-2 ${c.status === 'DIFFERENCE' ? 'font-semibold text-danger-700' : ''}`}>{c.difference === null ? '—' : formatINR(c.difference)}</td>
                <td className="px-4 py-2"><Badge variant={STATUS_TONE[c.status] ?? 'neutral'}>{c.status === 'PENDING' ? 'Not filed yet' : c.status === 'OK' ? 'Agrees' : 'Differs'}</Badge></td>
              </tr>
            ))}
          </tbody>
        </table>
      </SolidPanel>

      <div className="grid gap-5 xl:grid-cols-2">
        <ReturnPanel title="GSTR-1" row={r1} returnType="GSTR1" gstin={gstin} period={period}
          canPrepare={canPrepare} canFile={canFile} banks={banks}>
          {r1 ? (
            <table className="w-full border-collapse text-sm">
              <thead><tr>
                <th className={`${th} text-left`}>Section</th><th className={`${th} text-right`}>Docs</th>
                <th className={`${th} text-right`}>Taxable</th><th className={`${th} text-right`}>Tax</th>
              </tr></thead>
              <tbody>
                {((r1.computed.sections ?? []) as { section: string; documents: number; taxable: string; igst: string; cgst: string; sgst: string }[]).map((s) => (
                  <tr key={s.section} className="border-t border-ink-100">
                    <td className="px-4 py-2">{s.section}</td>
                    <td className="numeric px-4 py-2">{s.documents}</td>
                    <td className="numeric px-4 py-2">{formatINR(fromDb(s.taxable))}</td>
                    <td className="numeric px-4 py-2">{formatINR(add(fromDb(s.igst), fromDb(s.cgst), fromDb(s.sgst)))}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          ) : <p className="px-4 py-6 text-sm text-ink-500">Prepare the return to take a snapshot of the month&rsquo;s outward supplies.</p>}
          {amendments.length > 0 && (
            <div className="border-t border-ink-100 px-4 py-3">
              <p className="mb-2 text-xs font-semibold text-warning-800">To report as amendments in this return</p>
              <ul className="space-y-1 text-xs text-ink-700">
                {amendments.map((a) => (
                  <li key={a.key}><Badge variant="warning" className="mr-1">{a.kind.replace(/_/g, ' ').toLowerCase()}</Badge>
                    <span className="font-mono">{a.documentNumber}</span> ({formatDate(a.documentDate)}) — {a.detail}</li>
                ))}
              </ul>
            </div>
          )}
        </ReturnPanel>

        <ReturnPanel title="GSTR-3B" row={r3} returnType="GSTR3B" gstin={gstin} period={period}
          canPrepare={canPrepare} canFile={canFile} banks={banks}>
          <table className="w-full border-collapse text-sm">
            <thead><tr>
              <th className={`${th} text-left`}>Table</th><th className={`${th} text-right`}>Value</th>
              <th className={`${th} text-right`}>IGST</th><th className={`${th} text-right`}>CGST</th><th className={`${th} text-right`}>SGST</th>
            </tr></thead>
            <tbody>
              {working.map((w) => (
                <tr key={w.section} className={`border-t border-ink-100 ${w.section === '4(C)' ? 'bg-ink-50 font-semibold' : ''} ${w.section === '3.1(!)' ? 'text-warning-800' : ''}`}>
                  <td className="px-4 py-2"><span className="font-mono text-xs">{w.section}</span><span className="block text-[11px] text-ink-500">{w.description}</span></td>
                  <td className="numeric px-4 py-2">{w.taxable === null ? '' : formatINR(w.taxable)}</td>
                  <td className="numeric px-4 py-2">{formatINR(w.igst)}</td>
                  <td className="numeric px-4 py-2">{formatINR(w.cgst)}</td>
                  <td className="numeric px-4 py-2">{formatINR(w.sgst)}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <div className="border-t border-ink-100 px-4 py-3">
            <p className="mb-2 text-xs font-semibold text-ink-700">Set-off (rule 88A: IGST credit first; CGST and SGST never cross)</p>
            <table className="w-full border-collapse text-xs">
              <thead><tr className="text-ink-500">
                <th className="py-1 text-left">Head</th><th className="py-1 text-right">Liability</th>
                <th className="py-1 text-right">by IGST</th><th className="py-1 text-right">by CGST</th>
                <th className="py-1 text-right">by SGST</th><th className="py-1 text-right">Cash (incl. RCM)</th>
                <th className="py-1 text-right">Credit left</th>
              </tr></thead>
              <tbody>
                {setoff.map((s) => (
                  <tr key={s.head} className="border-t border-ink-100">
                    <td className="py-1">{s.head}</td>
                    <td className="numeric py-1">{formatINR(s.liability)}</td>
                    <td className="numeric py-1">{formatINR(s.byIgst)}</td>
                    <td className="numeric py-1">{formatINR(s.byCgst)}</td>
                    <td className="numeric py-1">{formatINR(s.bySgst)}</td>
                    <td className="numeric py-1 font-semibold">{formatINR(s.cash)}</td>
                    <td className="numeric py-1">{formatINR(s.closing)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </ReturnPanel>
      </div>
    </div>
  );
}

async function ReturnPanel({
  title, row, returnType, gstin, period, canPrepare, canFile, banks, children,
}: {
  readonly title: string;
  readonly row: GstReturnRow | undefined;
  readonly returnType: 'GSTR1' | 'GSTR3B';
  readonly gstin: string;
  readonly period: string;
  readonly canPrepare: boolean;
  readonly canFile: boolean;
  readonly banks: readonly { value: string; label: string }[];
  readonly children: React.ReactNode;
}) {
  const totals = (row?.computed.totals ?? {}) as Totals;
  const setoff = (row?.computed.setoff ?? []) as { tax_head: string; liability: string }[];
  const liability = (head: string) => setoff.find((s) => s.tax_head === head)?.liability ?? '0';
  const working = (row?.computed.working ?? []) as { section: string; igst_amount: string; cgst_amount: string; sgst_amount: string; taxable_value: string | null }[];
  const itc = working.find((w) => w.section === '4(C)');
  const taxable = returnType === 'GSTR1' ? totals.taxable
    : working.filter((w) => w.section === '3.1(a)' || w.section === '3.1(b)').reduce((a, w) => a + Number(w.taxable_value ?? 0), 0).toFixed(2);

  return (
    <Panel className="overflow-hidden">
      <PanelHeader className="flex flex-wrap items-center justify-between gap-2">
        <PanelTitle>{title}</PanelTitle>
        {row ? <Badge variant={STATUS_TONE[row.status] ?? 'neutral'}>{row.status.replace('_', ' ').toLowerCase()}</Badge>
          : <Badge variant="neutral">not prepared</Badge>}
      </PanelHeader>
      <SolidPanel className="m-3 overflow-hidden">{children}</SolidPanel>
      <PanelContent className="space-y-3">
        {row?.status === 'FILED' && (
          <p className="text-sm text-ink-700">
            Filed {row.filedOn ? formatDate(row.filedOn) : ''} · ARN <span className="font-mono">{row.arn}</span>
            {row.filedTax !== null && <> · tax {formatINR(row.filedTax)}</>}
            {row.challanCin && <> · challan CIN <span className="font-mono">{row.challanCin}</span></>}
            {row.setoffJournalId && <> · <Link href={`/accounting/journals/${row.setoffJournalId}`} className="text-brand-700 hover:underline">set-off journal</Link></>}
          </p>
        )}
        {canPrepare && row?.status !== 'FILED' && (
          <ActionForm action={prepareReturnAction} submitLabel={row ? 'Re-prepare from the books' : 'Prepare'} columns={1}
            fixed={{ returnType, gstin, period }} fields={[]} />
        )}
        {canFile && row?.status === 'PREPARED' && (row.isPreparer
          ? <p className="text-xs text-ink-500">Prepared by you: someone else signs it off.</p>
          : <ActionForm action={signOffReturnAction} submitLabel="Sign off" columns={1} fixed={{ returnId: row.id }}
              confirm={`Sign off the ${title} figures as correct for filing?`} fields={[]} />)}
        {canFile && row?.status === 'SIGNED_OFF' && (
          <ActionForm action={recordFilingAction} submitLabel="Record filing" columns={3} fixed={{ returnId: row.id }}
            confirm={`Record ${title} as filed? A filed return cannot be changed.`}
            fields={[
              { name: 'arn', label: 'ARN', required: true },
              { name: 'filedOn', label: 'Filed on', type: 'date', required: true, defaultValue: new Date().toISOString().slice(0, 10) },
              { name: 'taxable', label: 'Taxable value filed', type: 'number', step: '0.01', defaultValue: taxable ?? '0' },
              { name: 'igst', label: 'IGST filed', type: 'number', step: '0.01', defaultValue: returnType === 'GSTR1' ? totals.igst ?? '0' : liability('IGST') },
              { name: 'cgst', label: 'CGST filed', type: 'number', step: '0.01', defaultValue: returnType === 'GSTR1' ? totals.cgst ?? '0' : liability('CGST') },
              { name: 'sgst', label: 'SGST filed', type: 'number', step: '0.01', defaultValue: returnType === 'GSTR1' ? totals.sgst ?? '0' : liability('SGST') },
              ...(returnType === 'GSTR3B' ? [
                { name: 'itcIgst', label: 'ITC IGST claimed', type: 'number' as const, step: '0.01', defaultValue: itc?.igst_amount ?? '0' },
                { name: 'itcCgst', label: 'ITC CGST claimed', type: 'number' as const, step: '0.01', defaultValue: itc?.cgst_amount ?? '0' },
                { name: 'itcSgst', label: 'ITC SGST claimed', type: 'number' as const, step: '0.01', defaultValue: itc?.sgst_amount ?? '0' },
                { name: 'cpin', label: 'Challan CPIN' },
                { name: 'cin', label: 'Challan CIN' },
                { name: 'challanAmount', label: 'Challan amount', type: 'number' as const, step: '0.01' },
              ] : []),
            ]} />
        )}
        {canFile && returnType === 'GSTR3B' && row?.status === 'FILED' && !row.setoffJournalId && (
          <ActionForm action={postSetoffAction} submitLabel="Post set-off and payment" columns={2} fixed={{ returnId: row.id }}
            confirm="Post the set-off: output tax cleared by credit, and the cash paid from this bank account?"
            fields={[{ name: 'bankAccountId', label: 'Paid from', type: 'select', required: true, options: [...banks] }]} />
        )}
        {row && (
          <AttachmentsPanel entityType="GST_FILING" entityId={row.id} revalidate="/gst/returns" />
        )}
      </PanelContent>
    </Panel>
  );
}
