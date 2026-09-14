import type { Metadata } from 'next';
import Link from 'next/link';
import { ArrowLeft } from 'lucide-react';

import { requirePermission } from '@/server/auth/tenant-context';
import { supplierImportTemplate } from '@/server/services/masters/supplier-import';
import { SupplierImport } from '@/components/forms/supplier-import';
import { PageHeader } from '@/components/data-table/data-table';
import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';

export const metadata: Metadata = { title: 'Import suppliers' };
export const dynamic = 'force-dynamic';

export default async function SupplierUploadPage() {
  await requirePermission('masters.suppliers.manage');

  return (
    <>
      <PageHeader
        title="Import suppliers"
        description="Bring an existing supplier list in from a CSV file (spec §14, §44)."
        action={
          <Button variant="secondary" size="sm" asChild>
            <Link href="/masters/suppliers"><ArrowLeft aria-hidden />Suppliers</Link>
          </Button>
        }
      />

      <Panel className="mb-4 p-4">
        <p className="text-sm text-ink-700">
          Nothing is written until you press <strong>Confirm import</strong>, and confirming is
          blocked while any row has an error.
        </p>
        <p className="mt-2 text-sm text-ink-600">
          Only <code className="rounded bg-ink-100 px-1 font-mono text-xs">name</code> is required —
          an OEM account often has nothing else. Duplicates are caught on supplier code, GSTIN and
          name: the same supplier entered twice splits a payable across two ledgers, and that is
          usually noticed only when someone chases a balance that looks too small.
        </p>
      </Panel>

      <SupplierImport template={supplierImportTemplate()} />
    </>
  );
}
