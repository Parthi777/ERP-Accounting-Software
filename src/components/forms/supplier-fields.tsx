import type { FieldGroup } from '@/components/forms/master-form';

/**
 * The supplier form, described once and used by both the create and the edit
 * route — spec §41, §44.
 *
 * There is no code field: `supplier_code` is issued by a database trigger on
 * insert, exactly as `customer_code` is, so it cannot be supplied by the client
 * and stay unique.
 */
export const SUPPLIER_FIELD_GROUPS: readonly FieldGroup[] = [
  {
    title: 'Supplier',
    fields: [
      {
        name: 'name',
        label: 'Supplier name',
        type: 'text' as const,
        required: true,
        wide: true,
        placeholder: 'Sundaram Auto Components Ltd',
      },
      {
        name: 'supplier_type',
        label: 'Type',
        type: 'select' as const,
        required: true,
        options: [
          { value: 'GOODS', label: 'Goods' },
          { value: 'SERVICE', label: 'Service' },
          { value: 'OEM', label: 'OEM' },
        ],
      },
      {
        name: 'status',
        label: 'Status',
        type: 'select' as const,
        required: true,
        options: [
          { value: 'ACTIVE', label: 'Active' },
          { value: 'INACTIVE', label: 'Inactive' },
          { value: 'BLOCKED', label: 'Blocked' },
        ],
      },
    ],
  },
  {
    title: 'Contact',
    fields: [
      { name: 'contact_person', label: 'Contact person', type: 'text' as const },
      { name: 'mobile', label: 'Mobile', type: 'text' as const, maxLength: 10, placeholder: '9840012345' },
      { name: 'email', label: 'Email', type: 'text' as const },
      { name: 'city', label: 'City', type: 'text' as const },
      { name: 'state', label: 'State', type: 'text' as const },
    ],
  },
  {
    title: 'Tax and terms',
    description:
      'The GSTIN appears on purchase documents. Credit days drive the ageing of what is owed to this supplier.',
    fields: [
      { name: 'gstin', label: 'GSTIN', type: 'text' as const, mono: true, maxLength: 15 },
      { name: 'credit_days', label: 'Credit days', type: 'number' as const, step: '1', suffix: 'days' },
    ],
  },
];
