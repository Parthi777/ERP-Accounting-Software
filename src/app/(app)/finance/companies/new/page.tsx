import type { Metadata } from 'next';

import { requirePermission } from '@/server/auth/tenant-context';
import { getPickerOptions } from '@/server/services/masters/masters-service';
import { PageHeader } from '@/components/data-table/data-table';
import { MasterForm } from '@/components/forms/master-form';

export const metadata: Metadata = { title: 'New finance company' };
export const dynamic = 'force-dynamic';

export default async function Page() {
  await requirePermission('finance.companies.manage');
  const pickers = await getPickerOptions();

  const groups = [
    {
      title: 'Company',
      fields: [
        { name: 'code', label: 'Code', type: 'text' as const, required: true, mono: true, maxLength: 30, placeholder: 'TVSCREDIT' },
        { name: 'name', label: 'Company name', type: 'text' as const, required: true, placeholder: 'TVS Credit Services Ltd' },
        { name: 'contact_person', label: 'Contact person', type: 'text' as const },
        { name: 'mobile', label: 'Mobile', type: 'text' as const, maxLength: 10, placeholder: '9840012345' },
        { name: 'email', label: 'Email', type: 'text' as const },
        { name: 'gstin', label: 'GSTIN', type: 'text' as const, mono: true, maxLength: 15 },
        { name: 'status', label: 'Status', type: 'select' as const, required: true, options: [
          { value: 'ACTIVE', label: 'Active' }, { value: 'INACTIVE', label: 'Inactive' },
        ] },
      ],
    },
    {
      title: 'Accounting',
      description: 'The ledger account this company\u2019s balance rolls into. Spec §25 requires a separate ledger per company.',
      fields: [
        { name: 'ledger_account_id', label: 'Ledger account', type: 'select' as const, wide: true,
          options: pickers.accounts.map((o) => ({ value: o.id, label: o.label })) },
        { name: 'commission_percent', label: 'Commission', type: 'number' as const, step: '0.001', suffix: '%' },
      ],
    },
  ];
  const defaults = { status: 'ACTIVE', commission_percent: 0 };

  return (
    <div className="mx-auto max-w-3xl">
      <PageHeader title="New finance company" />
      <MasterForm
        kind="finance_company"
        mode="create"
        groups={groups}
        defaultValues={defaults}
        returnTo="/finance/companies"
        title="finance company"
      />
    </div>
  );
}
