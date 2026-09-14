import type { Metadata } from 'next';
import Link from 'next/link';
import { ArrowLeft } from 'lucide-react';

import { requirePermission } from '@/server/auth/tenant-context';
import { customerImportTemplate } from '@/server/services/customers/customer-import';
import { CustomerImport } from '@/components/forms/customer-import';
import { PageHeader } from '@/components/data-table/data-table';
import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';

export const metadata: Metadata = { title: 'Import customers' };
export const dynamic = 'force-dynamic';

export default async function CustomerUploadPage() {
  await requirePermission('customers.import');

  return (
    <>
      <PageHeader
        title="Import customers"
        description="Bring an existing customer list in from a CSV file (spec §11, §14)."
        action={
          <Button variant="secondary" size="sm" asChild>
            <Link href="/customers"><ArrowLeft aria-hidden />Customers</Link>
          </Button>
        }
      />

      <Panel className="mb-4 p-4">
        <p className="text-sm text-ink-700">
          Nothing is written until you press <strong>Confirm import</strong>, and confirming is
          blocked while any row has an error — so the file either goes in whole or not at all.
        </p>
        <p className="mt-2 text-sm text-ink-600">
          Leave <code className="rounded bg-ink-100 px-1 font-mono text-xs">customer_code</code> blank
          to have IDs issued for you. Fill it in to keep the numbers you already use — worth doing if
          your old invoices and paper records carry them, because renumbering makes every historical
          document unfindable by the number printed on it.
        </p>
      </Panel>

      <CustomerImport template={customerImportTemplate()} />
    </>
  );
}
