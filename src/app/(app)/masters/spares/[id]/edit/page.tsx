import type { Metadata } from 'next';
import { notFound } from 'next/navigation';

import { requirePermission } from '@/server/auth/tenant-context';
import { getPickerOptions, getMasterRecord } from '@/server/services/masters/masters-service';
import { PageHeader } from '@/components/data-table/data-table';
import { MasterForm } from '@/components/forms/master-form';

export const metadata: Metadata = { title: 'Edit item' };
export const dynamic = 'force-dynamic';

export default async function Page({ params }: { params: Promise<{ id: string }> }) {
  await requirePermission('inventory.items.manage');
  const { id } = await params;
  const record = await getMasterRecord('inventory_item', id);
  if (!record) notFound();
  const pickers = await getPickerOptions();

  const groups = [
    {
      title: 'Item',
      fields: [
        { name: 'item_code', label: 'Item code', type: 'text' as const, required: true, mono: true, maxLength: 30, placeholder: 'ACC-FLOORMAT' },
        { name: 'name', label: 'Name', type: 'text' as const, required: true },
        { name: 'item_type', label: 'Type', type: 'select' as const, required: true, options: [
          { value: 'ACCESSORY', label: 'Accessory' }, { value: 'SPARE', label: 'Spare part' },
        ] },
        { name: 'uom', label: 'Unit of measure', type: 'select' as const, required: true, options: [
          { value: 'NOS', label: 'Nos' }, { value: 'SET', label: 'Set' }, { value: 'PAIR', label: 'Pair' },
          { value: 'LTR', label: 'Litre' }, { value: 'KG', label: 'Kilogram' },
          { value: 'MTR', label: 'Metre' }, { value: 'BOX', label: 'Box' },
        ] },
        { name: 'brand', label: 'Brand', type: 'text' as const },
        { name: 'category', label: 'Category', type: 'text' as const },
        { name: 'is_fitment', label: 'Can be fitted to a vehicle at sale', type: 'checkbox' as const, wide: true },
        { name: 'status', label: 'Status', type: 'select' as const, required: true, options: [
          { value: 'ACTIVE', label: 'Active' }, { value: 'INACTIVE', label: 'Inactive' },
        ] },
      ],
    },
    {
      title: 'Pricing',
      description: 'Standard cost is indicative. Actual cost is held per stock lot, since two lots of the same item can be bought at different prices.',
      fields: [
        { name: 'standard_cost', label: 'Standard cost', type: 'number' as const, step: '0.01', suffix: '₹' },
        { name: 'selling_price', label: 'Selling price', type: 'number' as const, step: '0.01', suffix: '₹' },
        { name: 'reorder_level', label: 'Reorder level', type: 'number' as const, step: '0.001' },
      ],
    },
    {
      title: 'Tax',
      fields: [
        { name: 'hsn_code_id', label: 'HSN code', type: 'select' as const,
          options: pickers.hsn.map((o) => ({ value: o.id, label: o.label })) },
        { name: 'tax_code', label: 'Tax code', type: 'select' as const,
          options: pickers.taxCodes.map((o) => ({ value: o.code, label: o.label })) },
      ],
    },
  ];


  return (
    <div className="mx-auto max-w-3xl">
      <PageHeader title="Edit spar" />
      <MasterForm
        kind="inventory_item"
        mode="edit"
        recordId={id}
        groups={groups}
        defaultValues={record}
        returnTo="/masters/spares"
        title="item"
      />
    </div>
  );
}
