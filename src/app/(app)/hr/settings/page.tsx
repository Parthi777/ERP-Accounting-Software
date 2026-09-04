import type { Metadata } from 'next';
import Link from 'next/link';
import { ArrowLeft } from 'lucide-react';

import { getShifts, getLeaveTypes } from '@/server/services/hr/hr-service';
import { requirePermission, hasPermission } from '@/server/auth/tenant-context';
import { PageHeader } from '@/components/data-table/data-table';
import { HrSettings } from '@/components/hr/hr-settings';
import { Button } from '@/components/ui/button';

export const metadata: Metadata = { title: 'Shifts and leave' };
export const dynamic = 'force-dynamic';

/**
 * Spec §12. The two things Attendance measures a day against: the shift that
 * says what the day should have been, and the leave types that explain a day
 * that was not worked.
 */
export default async function Page() {
  const context = await requirePermission('masters.employees.view');
  const [shifts, leaveTypes] = await Promise.all([getShifts(), getLeaveTypes()]);

  return (
    <>
      <PageHeader
        title="Shifts and leave"
        description="What a working day looks like, and what counts as leave when it is not worked (spec §12)."
        action={
          <Button variant="secondary" size="sm" asChild>
            <Link href="/hr"><ArrowLeft aria-hidden />Employees</Link>
          </Button>
        }
      />
      <HrSettings
        shifts={shifts}
        leaveTypes={leaveTypes}
        canManage={hasPermission(context, 'hr.settings.manage')}
      />
    </>
  );
}
