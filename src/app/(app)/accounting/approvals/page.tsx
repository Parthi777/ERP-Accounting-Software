import Link from 'next/link';
import type { Metadata } from 'next';

import { getApprovals, type ApprovalRow, type ApprovalStatus } from '@/server/services/approvals/approval-service';
import { requireTenantContext } from '@/server/auth/tenant-context';
import { PageHeader } from '@/components/data-table/data-table';
import { Panel, SolidPanel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { ApprovalDecision } from '@/components/approvals/approval-decision';
import { formatINR, fromDb } from '@/lib/money';
import { formatDate, formatDateTime } from '@/lib/format';
import { cn } from '@/lib/utils';

export const metadata: Metadata = { title: 'Approvals' };
export const dynamic = 'force-dynamic';

const TABS: { status: ApprovalStatus | 'ALL'; label: string }[] = [
  { status: 'PENDING', label: 'Waiting' },
  { status: 'APPROVED', label: 'Approved' },
  { status: 'REJECTED', label: 'Rejected' },
  { status: 'ALL', label: 'All' },
];

const TONE: Record<ApprovalStatus, 'warning' | 'positive' | 'danger' | 'neutral'> = {
  PENDING: 'warning',
  APPROVED: 'positive',
  REJECTED: 'danger',
  WITHDRAWN: 'neutral',
};

/**
 * Maker-checker — spec §6, §23, §35 (0081).
 *
 * Manual journals and stock adjustments wait here when the dealer has switched
 * approval on (Administration → Settings). Nothing posts or moves until a
 * second person approves; a rejection carries its reason back to the maker.
 */
export default async function ApprovalsPage({
  searchParams,
}: {
  searchParams: Promise<{ status?: string }>;
}) {
  const context = await requireTenantContext();
  const params = await searchParams;
  const tab = TABS.find((t) => t.status === params.status) ?? TABS[0]!;
  const rows = await getApprovals(tab.status);

  const canDecide = (row: ApprovalRow) =>
    context.permissions.has(row.kind === 'MANUAL_JOURNAL' ? 'accounting.journals.approve' : 'inventory.stock.approve');

  return (
    <div>
      <PageHeader
        title="Approvals"
        description="Manual journals and stock adjustments waiting for a second person. The one who submits cannot approve."
        count={rows.length}
      />

      <nav aria-label="Status" className="mb-4 flex flex-wrap gap-2">
        {TABS.map((t) => (
          <Link key={t.status} href={`/accounting/approvals?status=${t.status}`}
            aria-current={t.status === tab.status ? 'page' : undefined}
            className={cn('rounded-xl px-3 py-1.5 text-sm font-semibold',
              t.status === tab.status ? 'clay-raised text-brand-700' : 'text-ink-600 hover:bg-white/60')}>
            {t.label}
          </Link>
        ))}
      </nav>

      {rows.length === 0 ? (
        <Panel className="p-6 text-sm text-ink-600">
          Nothing here. Approval is switched on per dealer under Administration → Settings
          (<code className="text-xs">approvals.manual_journal</code>, <code className="text-xs">approvals.stock_adjustment</code>).
        </Panel>
      ) : (
        <div className="space-y-3">
          {rows.map((row) => (
            <SolidPanel key={row.id} className="p-4">
              <div className="flex flex-wrap items-start justify-between gap-4">
                <div className="min-w-0 flex-1 space-y-1">
                  <div className="flex flex-wrap items-center gap-2">
                    <Badge variant={row.kind === 'MANUAL_JOURNAL' ? 'info' : 'accent'}>
                      {row.kind === 'MANUAL_JOURNAL' ? 'Journal' : 'Stock adjustment'}
                    </Badge>
                    <Badge variant={TONE[row.status]}>{row.status}</Badge>
                    <span className="font-semibold text-ink-900">{row.summary}</span>
                  </div>
                  <p className="text-xs text-ink-500">
                    Submitted by {row.requestedByName} · {formatDateTime(row.requestedAt)}
                    {row.entryDate && ` · dated ${formatDate(row.entryDate)}`}
                    {row.decidedByName && ` · ${row.status.toLowerCase()} by ${row.decidedByName} ${row.decidedAt ? formatDateTime(row.decidedAt) : ''}`}
                  </p>
                  {row.decisionNote && <p className="text-sm text-ink-700">“{row.decisionNote}”</p>}
                  {row.lines.length > 0 && (
                    <table className="mt-2 w-full max-w-xl text-sm">
                      <tbody>
                        {row.lines.map((l, i) => (
                          <tr key={i} className="border-t border-ink-100">
                            <td className="py-1 pr-3 text-ink-700">{l.account}</td>
                            <td className="numeric py-1 pr-3">{l.debit ? formatINR(fromDb(String(l.debit))) : ''}</td>
                            <td className="numeric py-1">{l.credit ? formatINR(fromDb(String(l.credit))) : ''}</td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  )}
                  {row.kind === 'STOCK_ADJUSTMENT' && row.amount !== null && (
                    <p className="text-sm text-ink-600">Quantity {row.amount / 100}</p>
                  )}
                  {row.resultId && row.kind === 'MANUAL_JOURNAL' && (
                    <Link href={`/accounting/journals/${row.resultId}`} className="text-sm font-semibold text-brand-700 hover:underline">
                      Open the posted journal →
                    </Link>
                  )}
                </div>
                {row.status === 'PENDING' && (
                  <ApprovalDecision requestId={row.id} mine={row.mine} canDecide={canDecide(row)} />
                )}
              </div>
            </SolidPanel>
          ))}
        </div>
      )}
    </div>
  );
}
