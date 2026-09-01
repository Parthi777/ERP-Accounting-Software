import type { Metadata } from 'next';

import { getAuditLogs } from '@/server/services/org/org-service';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Badge } from '@/components/ui/badge';
import { formatDateTime } from '@/lib/format';
import type { AuditRow } from '@/server/services/org/org-service';

export const metadata: Metadata = { title: 'Audit Logs' };
export const dynamic = 'force-dynamic';

const ACTION_TONE: Record<string, 'positive' | 'info' | 'warning' | 'danger' | 'neutral'> = {
  CREATE: 'positive',
  UPDATE: 'info',
  DELETE: 'danger',
  POST: 'positive',
  APPROVE: 'positive',
  REJECT: 'danger',
  REVERSE: 'warning',
  CANCEL: 'warning',
  LOGIN: 'neutral',
  LOGOUT: 'neutral',
  BRANCH_SWITCH: 'neutral',
  PERMISSION_CHANGE: 'warning',
  DAY_CLOSE: 'info',
};

const columns: Column<AuditRow>[] = [
  {
    key: 'time',
    header: 'When',
    render: (row) => <span className="whitespace-nowrap text-ink-600">{formatDateTime(row.created_at)}</span>,
  },
  {
    key: 'action',
    header: 'Action',
    render: (row) => <Badge variant={ACTION_TONE[row.action] ?? 'neutral'}>{row.action}</Badge>,
  },
  {
    key: 'entity',
    header: 'Entity',
    render: (row) => (
      <span>
        <span className="block font-medium text-ink-800">{row.entity_type}</span>
        {row.entity_id && (
          <span className="block truncate font-mono text-[11px] text-ink-400">{row.entity_id}</span>
        )}
      </span>
    ),
  },
  {
    key: 'actor',
    header: 'By',
    render: (row) => row.actor ?? <span className="text-ink-400">System</span>,
  },
  {
    key: 'changed',
    header: 'Changed fields',
    render: (row) =>
      row.changed_fields && row.changed_fields.length > 0 ? (
        <span className="flex flex-wrap gap-1">
          {row.changed_fields.slice(0, 4).map((field) => (
            <code key={field} className="rounded bg-ink-100 px-1 text-[11px] text-ink-600">
              {field}
            </code>
          ))}
          {row.changed_fields.length > 4 && (
            <span className="text-[11px] text-ink-400">+{row.changed_fields.length - 4}</span>
          )}
        </span>
      ) : (
        <span className="text-ink-400">—</span>
      ),
  },
  {
    key: 'reason',
    header: 'Reason',
    render: (row) => row.reason ?? <span className="text-ink-400">—</span>,
  },
];

export default async function AuditPage() {
  const logs = await getAuditLogs(200);

  return (
    <div>
      <PageHeader
        title="Audit Logs"
        description="Append-only. Rows are written by database triggers and cannot be edited or deleted by anyone, including an administrator."
        count={logs.length}
      />
      <DataTable
        columns={columns}
        rows={logs}
        getRowKey={(row) => String(row.id)}
        caption="Audit trail"
        emptyMessage="No audit entries yet."
        maxHeight="40rem"
      />
    </div>
  );
}
