import type { Metadata } from 'next';

import { getGroupOptions } from '@/server/services/accounting/ledger-master-service';
import { requirePermission } from '@/server/auth/tenant-context';
import { PageHeader } from '@/components/data-table/data-table';
import { NewLedgerForm } from '@/components/accounting/ledger-master-forms';
import { CustomerForm } from '@/components/forms/customer-form';
import { MasterForm } from '@/components/forms/master-form';
import { SUPPLIER_FIELD_GROUPS } from '@/components/forms/supplier-fields';

export const metadata: Metadata = { title: 'Add ledger' };
export const dynamic = 'force-dynamic';

/**
 * Add a ledger — choose its group first, as in BUSY. Under Sundry Debtors the
 * ledger is a customer and under Sundry Creditors a supplier, so those groups
 * bring up the customer and supplier forms, each saved by its own master with
 * its own validation.
 */
export default async function NewLedgerPage() {
  const context = await requirePermission('accounting.coa.manage');
  const groups = await getGroupOptions();

  const partyForms = {
    DEBTORS: context.permissions.has('customers.create') ? (
      <CustomerForm
        mode="create"
        branches={context.accessibleBranches.map((b) => ({ id: b.id, name: b.name }))}
      />
    ) : (
      <p className="text-sm text-ink-600">Your role cannot add customers.</p>
    ),
    CREDITORS: context.permissions.has('masters.suppliers.manage') ? (
      <MasterForm kind="supplier" mode="create" groups={SUPPLIER_FIELD_GROUPS} returnTo="/accounting/ledgers" title="supplier" />
    ) : (
      <p className="text-sm text-ink-600">Your role cannot add suppliers.</p>
    ),
  };

  return (
    <div className="mx-auto max-w-4xl">
      <PageHeader
        title="Add ledger"
        description="Pick the group first. The code is suggested from the group; the opening balance is posted against Opening Balance Equity."
      />
      <NewLedgerForm groups={groups} partyForms={partyForms} />
    </div>
  );
}
