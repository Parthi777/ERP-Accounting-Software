import type { Metadata } from 'next';

import {
  getVehicleTransfers,
  getTransferableVehicles,
  type VehicleTransferRow,
} from '@/server/services/vehicles/transfer-service';
import { requirePermission, hasPermission } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { TransferDispatchForm } from '@/components/vehicles/transfer-dispatch-form';
import { TransferReceiveAction } from '@/components/vehicles/transfer-receive-action';
import { Panel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'Vehicle transfers' };
export const dynamic = 'force-dynamic';

const STATUS_TONE: Record<string, 'positive' | 'info' | 'neutral' | 'warning' | 'danger'> = {
  IN_TRANSIT: 'warning',
  RECEIVED: 'positive',
  CANCELLED: 'danger',
};

const STATUSES = ['ALL', 'IN_TRANSIT', 'RECEIVED', 'CANCELLED'];

export default async function Page({
  searchParams,
}: {
  searchParams: Promise<{ status?: string }>;
}) {
  const context = await requirePermission('vehicles.transfers.view');
  const params = await searchParams;
  const status = params.status ?? 'IN_TRANSIT';

  const canManage = hasPermission(context, 'vehicles.transfers.manage');

  const [rows, vehicles] = await Promise.all([
    getVehicleTransfers({ status, branchId: null }),
    canManage ? getTransferableVehicles(null) : Promise.resolve([]),
  ]);

  const columns: Column<VehicleTransferRow>[] = [
    {
      key: 'number',
      header: 'Transfer',
      render: (row) => (
        <span>
          <span className="block font-mono text-xs text-ink-700">{row.transferNumber}</span>
          <span className="block text-[11px] text-ink-400">{formatDate(row.dispatchedAt)}</span>
        </span>
      ),
    },
    {
      key: 'vehicle',
      header: 'Vehicle',
      render: (row) => (
        <span>
          <span className="block font-medium text-ink-800">{row.modelLabel}</span>
          <span className="block font-mono text-[11px] text-ink-400">{row.chassisNo}</span>
        </span>
      ),
    },
    {
      key: 'route',
      header: 'Route',
      render: (row) => (
        <span className="text-ink-700">
          {row.fromBranchName} <span className="text-ink-300">→</span> {row.toBranchName}
        </span>
      ),
    },
    {
      key: 'received',
      header: 'Received',
      render: (row) =>
        row.receivedAt ? formatDate(row.receivedAt) : <span className="text-ink-300">In transit</span>,
    },
    {
      key: 'remarks',
      header: 'Remarks',
      render: (row) =>
        row.remarks ? (
          <span className="line-clamp-2 max-w-xs text-ink-600">{row.remarks}</span>
        ) : (
          <span className="text-ink-300">—</span>
        ),
    },
    {
      key: 'status',
      header: 'Status',
      render: (row) => (
        <Badge variant={STATUS_TONE[row.status] ?? 'neutral'}>{row.status.replace('_', ' ')}</Badge>
      ),
    },
    {
      key: 'actions',
      header: '',
      render: (row) =>
        row.canReceive ? (
          <TransferReceiveAction transferId={row.id} toBranchName={row.toBranchName} />
        ) : null,
    },
  ];

  return (
    <>
      <PageHeader
        title="Vehicle transfers"
        description="Branch to branch, with an in-transit state so a unit on the road belongs to neither (spec §35)."
        count={rows.length}
      />

      {canManage && (
        <div className="mb-4">
          <TransferDispatchForm vehicles={vehicles} branches={context.accessibleBranches} />
        </div>
      )}

      <Panel className="mb-4 p-4">
        <form method="get" className="flex flex-wrap items-end gap-3">
          <div>
            <label htmlFor="status" className="mb-1.5 block text-xs font-medium text-ink-600">
              Status
            </label>
            <select
              id="status"
              name="status"
              defaultValue={status}
              className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
            >
              {STATUSES.map((s) => (
                <option key={s} value={s}>{s.replace('_', ' ')}</option>
              ))}
            </select>
          </div>
          <Button type="submit" variant="secondary" size="sm">Filter</Button>
        </form>
      </Panel>

      <DataTable
        columns={columns}
        rows={rows}
        getRowKey={(row) => row.id}
        emptyMessage={
          status === 'IN_TRANSIT' ? 'Nothing is in transit.' : 'No transfers match this filter.'
        }
        caption="Vehicle transfers"
      />
    </>
  );
}
