import Link from 'next/link';
import type { Metadata } from 'next';

import {
  claimCounts,
  getClaimPayBanks,
  listEmployeeClaims,
  type ClaimTab,
  type EmployeeClaimRow,
} from '@/server/services/hr/employee-claims-service';
import { resolveReviewAction, syncNowAction } from '@/server/services/hr/employee-claims-actions';
import { isHrConfigured } from '@/server/services/hr/hr-client';
import { requirePermission, hasPermission } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { SolidPanel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { ActionForm } from '@/components/forms/action-form';
import { ClaimsPayForm } from '@/components/hr/claims-pay-form';
import { formatDate } from '@/lib/format';
import { cn } from '@/lib/utils';

export const metadata: Metadata = { title: 'Claims to Pay' };
export const dynamic = 'force-dynamic';

const inr = new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', minimumFractionDigits: 2 });

const TABS: { key: ClaimTab; label: string }[] = [
  { key: 'topay', label: 'To pay' },
  { key: 'paid', label: 'Paid' },
  { key: 'mapping', label: 'Waiting for mapping' },
  { key: 'review', label: 'Needs review' },
  { key: 'cancelled', label: 'Taken back' },
];

/**
 * Employee claims approved in the HR app (0095). The cashier pays them here,
 * from the cash book; the HR app shows them paid. Claims whose branch or
 * expense head is not mapped yet wait under "Waiting for mapping" until the
 * accountant maps them under HR → HR App Link.
 */
export default async function ClaimsToPayPage({ searchParams }: { searchParams: Promise<{ tab?: string }> }) {
  const context = await requirePermission('hr.claims.view');
  const params = await searchParams;
  const tab = (TABS.find((t) => t.key === params.tab)?.key ?? 'topay') as ClaimTab;
  const canPay = hasPermission(context, 'hr.claims.pay');
  const canReview = hasPermission(context, 'hr.mapping.manage');

  const [claims, counts, banks] = await Promise.all([
    listEmployeeClaims(tab),
    claimCounts(),
    tab === 'topay' && canPay ? getClaimPayBanks() : Promise.resolve([]),
  ]);

  const paidColumns: Column<EmployeeClaimRow>[] = [
    { key: 'emp', header: 'Employee', render: (c) => <span>{c.employeeName}<span className="block text-[11px] text-ink-400">{c.branchName}</span></span> },
    { key: 'claim', header: 'Claim', render: (c) => <span>{c.title}<span className="block text-[11px] text-ink-400">{c.typeLabel}</span></span> },
    { key: 'paid', header: 'Paid', render: (c) => (c.paidAt ? formatDate(c.paidAt) : '—') },
    { key: 'ref', header: 'Voucher', render: (c) => <span className="font-mono text-xs">{c.paymentRef ?? '—'}</span> },
    {
      key: 'hr', header: 'HR app',
      render: (c) => c.callbackStatus === 'SENT' ? <Badge variant="positive">shows paid</Badge>
        : c.callbackStatus === 'FAILED' ? <span title={c.callbackError ?? ''}><Badge variant="danger">not told yet</Badge></span>
        : <Badge variant="warning">being told</Badge>,
    },
    { key: 'amt', header: 'Amount', numeric: true, render: (c) => inr.format(c.amount) },
  ];
  const otherColumns: Column<EmployeeClaimRow>[] = [
    { key: 'emp', header: 'Employee', render: (c) => <span>{c.employeeName}<span className="block text-[11px] text-ink-400">{c.branchName ?? 'branch not mapped'}</span></span> },
    { key: 'claim', header: 'Claim', render: (c) => <span>{c.title}<span className="block text-[11px] text-ink-400">{c.typeLabel}</span></span> },
    { key: 'note', header: 'Note', render: (c) => <span className="text-xs text-ink-600">{c.reviewNote ?? (tab === 'mapping' ? 'Map its branch and expense head under HR → HR App Link' : '—')}</span> },
    { key: 'amt', header: 'Amount', numeric: true, render: (c) => inr.format(c.amount) },
    ...(tab === 'review' && canReview
      ? [{
          key: 'act', header: '',
          render: (c: EmployeeClaimRow) => (
            <div className="w-64">
              <ActionForm fields={[{ name: 'note', label: 'What was done', required: true, placeholder: 'Recovered from salary' }]}
                fixed={{ id: c.id }} action={resolveReviewAction} submitLabel="Mark dealt with" columns={1} />
            </div>
          ),
        } as Column<EmployeeClaimRow>]
      : []),
  ];

  return (
    <div className="space-y-4">
      <PageHeader
        title="Claims to Pay"
        description="Expense claims approved in the HR app. Paid here from the cash book, they show as paid in the HR app."
        action={isHrConfigured() ? (
          <div className="w-32">
            <ActionForm fields={[]} action={syncNowAction} submitLabel="Sync now" columns={1} />
          </div>
        ) : undefined}
      />
      {!isHrConfigured() && (
        <p className="rounded-xl bg-warning-50 px-3 py-2 text-sm text-warning-800">
          The HR app is not connected yet. See HR → HR App Link.
        </p>
      )}

      <nav className="flex flex-wrap gap-1 text-sm" aria-label="Views">
        {TABS.map((t) => (
          <Link key={t.key} href={`/cash-book/claims?tab=${t.key}`}
            className={cn('rounded-lg px-3 py-1.5', tab === t.key ? 'bg-brand-50 font-medium text-brand-800' : 'text-ink-600 hover:bg-ink-50')}>
            {t.label}{counts[t.key] > 0 && <span className="ml-1 text-[11px] text-ink-400">{counts[t.key]}</span>}
          </Link>
        ))}
      </nav>

      {tab === 'topay' ? (
        <SolidPanel className="p-2">
          <ClaimsPayForm claims={claims} banks={banks} branchName={context.activeBranch?.name ?? null} canPay={canPay} />
        </SolidPanel>
      ) : (
        <DataTable columns={tab === 'paid' ? paidColumns : otherColumns} rows={claims} getRowKey={(c) => c.id}
          caption="Employee claims" emptyMessage="Nothing here." maxHeight="40rem" />
      )}
    </div>
  );
}
