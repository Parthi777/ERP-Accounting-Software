import type { Metadata } from 'next';
import Link from 'next/link';
import { ArrowLeft } from 'lucide-react';

import { getAttendanceOverview } from '@/server/services/hr/attendance-service';
import { requirePermission } from '@/server/auth/tenant-context';
import { PageHeader } from '@/components/data-table/data-table';
import { AttendanceView } from '@/components/hr/attendance-view';
import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { monthRange } from '@/lib/period';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'Attendance' };
export const dynamic = 'force-dynamic';

/**
 * Spec §12, §40. The register is a mirror of the dealer's own attendance system;
 * this application never becomes a second place people clock in.
 */
export default async function Page({
  searchParams,
}: {
  searchParams: Promise<{ from?: string; to?: string }>;
}) {
  await requirePermission('hr.attendance.view');
  const params = await searchParams;
  const { from, to } = monthRange(params.from, params.to);

  const overview = await getAttendanceOverview({ from, to, branchId: null });

  return (
    <>
      <PageHeader
        title="Attendance"
        description={`Mirrored from the attendance system, ${formatDate(from)} – ${formatDate(to)}. Payroll reads this copy, so it does not depend on that system being reachable (spec §40).`}
        count={overview.summary.length}
        action={
          <Button variant="secondary" size="sm" asChild>
            <Link href="/hr"><ArrowLeft aria-hidden />Employees</Link>
          </Button>
        }
      />

      <Panel className="mb-4 p-4">
        <form method="get" className="flex flex-wrap items-end gap-3">
          <div>
            <label htmlFor="from" className="mb-1.5 block text-xs font-medium text-ink-600">From</label>
            <input id="from" name="from" type="date" defaultValue={from}
              className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm" />
          </div>
          <div>
            <label htmlFor="to" className="mb-1.5 block text-xs font-medium text-ink-600">To</label>
            <input id="to" name="to" type="date" defaultValue={to}
              className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm" />
          </div>
          <Button type="submit" variant="secondary" size="sm">Show period</Button>
        </form>
      </Panel>

      <AttendanceView overview={overview} />
    </>
  );
}
