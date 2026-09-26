import type { Metadata } from 'next';

import { getHrLinkStatus } from '@/server/services/hr/employee-claims-service';
import { importPayrollAction, mapBranchAction, mapHeadAction, syncNowAction } from '@/server/services/hr/employee-claims-actions';
import { getChart } from '@/server/services/accounting/ledger-master-service';
import { requirePermission, hasPermission } from '@/server/auth/tenant-context';
import { PageHeader } from '@/components/data-table/data-table';
import { Panel, PanelContent, PanelHeader, PanelTitle } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { ActionForm } from '@/components/forms/action-form';
import { formatDateTime } from '@/lib/format';

export const metadata: Metadata = { title: 'HR App Link' };
export const dynamic = 'force-dynamic';

/**
 * The HR Payroll app, connected (0095). Two maps decide where things land:
 * each HR branch to a branch here, and each claim type to the ledger it is
 * booked to. A claim whose branch or head is not mapped waits and is booked
 * the moment it is. Payroll finalised in the HR app comes in as draft runs.
 */
export default async function HrIntegrationPage() {
  const context = await requirePermission('hr.mapping.manage');
  const [status, chart] = await Promise.all([getHrLinkStatus(), getChart()]);
  const branches = context.accessibleBranches.map((b) => ({ value: b.id, label: b.name }));
  const ledgers = chart
    .filter((a) => !a.isGroup && a.status === 'ACTIVE' && (a.type === 'EXPENSE' || a.type === 'ASSET' || a.type === 'LIABILITY'))
    .map((a) => ({ value: a.id, label: `${a.code} · ${a.name}` }));

  return (
    <div className="mx-auto max-w-5xl space-y-4">
      <PageHeader
        title="HR App Link"
        description="Claims approved in the HR app are booked and paid here; payroll finalised there is brought in to post."
        action={status.configured ? (
          <div className="w-32"><ActionForm fields={[]} action={syncNowAction} submitLabel="Sync now" columns={1} /></div>
        ) : undefined}
      />

      <Panel className="p-5 text-sm">
        {status.configured ? (
          <div className="flex flex-wrap items-center gap-3">
            <Badge variant="positive">connected</Badge>
            <span>{status.workspaceName ?? 'HR workspace'}</span>
            <span className="text-ink-500">last synced {status.lastClaimsSyncAt ? formatDateTime(status.lastClaimsSyncAt) : 'never'}</span>
            {status.lastError && <span className="text-danger-700">Last problem: {status.lastError}</span>}
          </div>
        ) : (
          <div className="space-y-1 text-ink-700">
            <p><Badge variant="warning">not connected</Badge></p>
            <p>
              In the HR app open <strong>Accounting ERP → Connect</strong>, give it this address as the webhook:
              <code className="mx-1 rounded bg-ink-50 px-1">/api/integrations/hr/webhook</code> on this app&apos;s domain,
              then set <code>HR_API_BASE_URL</code>, <code>HR_API_KEY</code>, <code>HR_WEBHOOK_SECRET</code> and
              <code> HR_DEALER_CODE</code> on this app (Railway variables) and redeploy.
            </p>
          </div>
        )}
      </Panel>

      <Panel>
        <PanelHeader><PanelTitle>Branches</PanelTitle></PanelHeader>
        <PanelContent>
          {status.branches.length === 0 ? (
            <p className="text-sm text-ink-500">HR branches appear here after the first sync.</p>
          ) : (
            <ul className="divide-y divide-ink-100">
              {status.branches.map((b) => (
                <li key={b.hrBranchId} className="grid items-end gap-3 py-3 sm:grid-cols-[1fr_2fr]">
                  <div className="text-sm">
                    <span className="font-medium text-ink-800">{b.hrBranchName}</span>
                    <span className="block text-[11px] text-ink-400">in the HR app</span>
                  </div>
                  <ActionForm action={mapBranchAction} submitLabel="Save" columns={2} resetOnSuccess={false} fixed={{ hrBranchId: b.hrBranchId }}
                    fields={[{ name: 'branchId', label: 'Branch here', type: 'select', defaultValue: b.branchId ?? '', options: branches }]} />
                </li>
              ))}
            </ul>
          )}
        </PanelContent>
      </Panel>

      <Panel>
        <PanelHeader><PanelTitle>Claim types → ledgers</PanelTitle></PanelHeader>
        <PanelContent>
          <p className="mb-3 text-xs text-ink-500">
            Each approved claim is booked Dr this ledger, Cr 2770 Employee Claims Payable for the employee; paying it clears
            2770. Types appear as claims of that type arrive.
          </p>
          {status.heads.length === 0 ? (
            <p className="text-sm text-ink-500">No claim types have arrived yet.</p>
          ) : (
            <ul className="divide-y divide-ink-100">
              {status.heads.map((h) => (
                <li key={h.claimType} className="grid items-end gap-3 py-3 sm:grid-cols-[1fr_2fr]">
                  <div className="text-sm">
                    <span className="font-medium text-ink-800">{h.label}</span>
                    {!h.accountId && <Badge variant="warning" className="ml-2">not mapped</Badge>}
                  </div>
                  <ActionForm action={mapHeadAction} submitLabel="Save" columns={2} resetOnSuccess={false} fixed={{ claimType: h.claimType }}
                    fields={[{ name: 'accountId', label: 'Ledger', type: 'select', defaultValue: h.accountId ?? '', options: ledgers }]} />
                </li>
              ))}
            </ul>
          )}
        </PanelContent>
      </Panel>

      {hasPermission(context, 'hr.payroll.run') && (
        <Panel>
          <PanelHeader><PanelTitle>Payroll from the HR app</PanelTitle></PanelHeader>
          <PanelContent>
            <p className="mb-3 text-xs text-ink-500">
              Brings a month the HR app has finalised in as draft payroll runs, one per branch, with each employee&apos;s gross,
              PF, ESI, professional tax, TDS and net as the HR app worked them out. Review, post and pay them under HR → Payroll.
              A month already posted here is not brought in again.
            </p>
            <div className="max-w-sm">
              <ActionForm action={importPayrollAction} submitLabel="Bring in payroll" columns={1}
                fields={[{ name: 'month', label: 'Month', type: 'month', required: true }]} />
            </div>
          </PanelContent>
        </Panel>
      )}

      <Panel className="p-5 text-xs text-ink-500">
        Attendance comes from the same HR app through the attendance mirror (HR → Attendance → Sync) once
        <code className="mx-1">ATTENDANCE_API_BASE_URL</code> is set to the HR app&apos;s <code>/api/integration/v1</code> and
        <code className="mx-1">ATTENDANCE_API_KEY</code> to the same key.
      </Panel>
    </div>
  );
}
