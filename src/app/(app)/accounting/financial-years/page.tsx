import type { Metadata } from 'next';

import { listFinancialYears } from '@/server/services/accounting/ledger-master-service';
import {
  closeFinancialYearAction,
  createFinancialYearAction,
  reopenFinancialYearAction,
} from '@/server/services/accounting/ledger-master-actions';
import { requireTenantContext } from '@/server/auth/tenant-context';
import { PageHeader } from '@/components/data-table/data-table';
import { Panel, SolidPanel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { ActionForm } from '@/components/forms/action-form';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'Financial Years' };
export const dynamic = 'force-dynamic';

const TONE: Record<string, 'positive' | 'neutral' | 'warning'> = { OPEN: 'positive', CLOSED: 'neutral', LOCKED: 'warning' };

function nextYearName(lastEnd: string | undefined): string {
  if (!lastEnd) return 'the current financial year';
  const start = new Date(`${lastEnd}T00:00:00Z`);
  start.setUTCDate(start.getUTCDate() + 1);
  const y = start.getUTCFullYear();
  return `FY ${y}-${String((y + 1) % 100).padStart(2, '0')}`;
}

/**
 * Financial years — create the next one, close a year that has ended, reopen
 * one with a reason. Balances need no carry-forward entry: the balance sheet
 * already carries the result to date, and document numbers restart on their
 * own in a new year.
 */
export default async function FinancialYearsPage() {
  const context = await requireTenantContext();
  const years = await listFinancialYears();
  const canManage = context.permissions.has('accounting.periods.manage');
  const next = nextYearName(years[0]?.endDate);
  const today = new Date().toISOString().slice(0, 10);

  return (
    <div className="mx-auto max-w-4xl space-y-4">
      <PageHeader
        title="Financial Years"
        description="A closed year takes no more postings. Close years in order, after they end."
        count={years.length}
      />

      {canManage && (
        <Panel className="p-5">
          <h2 className="mb-1 text-sm font-semibold text-ink-900">Create {next}</h2>
          <p className="mb-4 text-xs text-ink-500">
            Starts the day after the last year ends and runs twelve months. Closing balances carry forward on their own; invoice and receipt numbers start again at 1.
          </p>
          <ActionForm
            fields={[]}
            action={createFinancialYearAction}
            submitLabel={`Create ${next}`}
            confirm={`Create ${next}?`}
            columns={1}
          />
        </Panel>
      )}

      <SolidPanel className="divide-y divide-ink-100">
        {years.length === 0 && <p className="p-5 text-sm text-ink-500">No financial years yet.</p>}
        {years.map((year) => (
          <div key={year.id} className="flex flex-wrap items-start justify-between gap-4 p-5">
            <div>
              <div className="flex items-center gap-2">
                <h3 className="text-sm font-semibold text-ink-900">{year.name}</h3>
                <Badge variant={TONE[year.status] ?? 'neutral'}>{year.status.toLowerCase()}</Badge>
                {year.startDate <= today && today <= year.endDate && <Badge variant="info">current</Badge>}
              </div>
              <p className="mt-0.5 text-xs text-ink-500">
                {formatDate(year.startDate)} – {formatDate(year.endDate)}
                {year.closedAt && <> · closed {formatDate(year.closedAt)}</>}
                {year.status === 'OPEN' && year.reason && <> · reopened: {year.reason}</>}
              </p>
            </div>
            {canManage && year.status === 'OPEN' && year.endDate < today && (
              <div className="w-48">
                <ActionForm
                  fields={[]}
                  fixed={{ periodId: year.id }}
                  action={closeFinancialYearAction}
                  submitLabel="Close year"
                  confirm={`Close ${year.name}? Nothing more can be posted into it until it is reopened.`}
                  columns={1}
                />
              </div>
            )}
            {canManage && year.status !== 'OPEN' && (
              <div className="w-full sm:w-80">
                <ActionForm
                  fields={[{ name: 'reason', label: 'Reason to reopen', required: true, placeholder: 'Late supplier bill found' }]}
                  fixed={{ periodId: year.id }}
                  action={reopenFinancialYearAction}
                  submitLabel="Reopen year"
                  columns={1}
                />
              </div>
            )}
          </div>
        ))}
      </SolidPanel>
    </div>
  );
}
