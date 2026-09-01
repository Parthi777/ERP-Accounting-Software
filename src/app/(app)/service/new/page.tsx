import type { Metadata } from 'next';
import Link from 'next/link';
import { ArrowLeft } from 'lucide-react';

import { getCustomerOptions } from '@/server/services/customers/customer-service';
import { requirePermission } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { PageHeader } from '@/components/data-table/data-table';
import { JobCardForm } from '@/components/service/job-card-form';
import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';

export const metadata: Metadata = { title: 'New job card' };
export const dynamic = 'force-dynamic';

export default async function Page() {
  const context = await requirePermission('service.jobcards.create');
  const supabase = await createSupabaseServerClient();

  const [customers, employees] = await Promise.all([
    getCustomerOptions(),
    supabase.from('employees').select('id, name, employee_code').eq('status', 'ACTIVE').order('name'),
  ]);

  return (
    <div className="mx-auto max-w-3xl">
      <Button variant="ghost" size="sm" asChild className="-ml-2 mb-2">
        <Link href="/service"><ArrowLeft aria-hidden />Job cards</Link>
      </Button>

      <PageHeader
        title="New job card"
        description="Books the vehicle in. Parts and labour are added when the bill is raised."
      />

      {!context.activeBranch ? (
        <Panel className="p-6 text-sm text-ink-600">
          Choose a branch in the sidebar first — a job card belongs to a workshop.
        </Panel>
      ) : customers.length === 0 ? (
        <Panel className="p-6 text-sm text-ink-600">
          No active customers yet.{' '}
          <Link href="/customers/new" className="text-brand-600 hover:underline">Create one</Link> to book a job in.
        </Panel>
      ) : (
        <JobCardForm
          customers={customers}
          employees={(employees.data ?? []).map((e) => ({ id: e.id, label: `${e.name} · ${e.employee_code}` }))}
          branchName={context.activeBranch.name}
        />
      )}
    </div>
  );
}
