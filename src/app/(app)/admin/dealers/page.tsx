import type { Metadata } from 'next';

import { getDealerProfile } from '@/server/services/org/org-service';
import { PageHeader } from '@/components/data-table/data-table';
import { Panel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { formatDate, formatMobile } from '@/lib/format';

export const metadata: Metadata = { title: 'Dealer' };
export const dynamic = 'force-dynamic';

export default async function DealerPage() {
  const dealer = await getDealerProfile();

  if (!dealer) {
    return (
      <div>
        <PageHeader title="Dealer" />
        <Panel className="p-6 text-sm text-ink-600">
          No dealer is visible to your account. Platform administrators provision dealers.
        </Panel>
      </div>
    );
  }

  const fields: { label: string; value: string }[] = [
    { label: 'Dealer code', value: dealer.code },
    { label: 'Legal name', value: dealer.legal_name },
    { label: 'Trade name', value: dealer.trade_name ?? '—' },
    { label: 'GSTIN', value: dealer.gstin ?? '—' },
    { label: 'PAN', value: dealer.pan ?? '—' },
    { label: 'Phone', value: formatMobile(dealer.phone) },
    { label: 'Email', value: dealer.email ?? '—' },
    {
      label: 'Address',
      value: [dealer.address_line1, dealer.address_line2, dealer.city, dealer.state, dealer.pincode]
        .filter(Boolean)
        .join(', ') || '—',
    },
    { label: 'State code', value: dealer.state_code ?? '—' },
    {
      label: 'Financial year starts',
      value: new Date(2000, dealer.fy_start_month - 1, 1).toLocaleString('en-IN', { month: 'long' }),
    },
    { label: 'Created', value: formatDate(dealer.created_at) },
  ];

  return (
    <div>
      <PageHeader
        title="Dealer"
        description="Tenant configuration. Every record in the system is scoped to this dealer."
        action={<Badge variant={dealer.status === 'ACTIVE' ? 'positive' : 'warning'}>{dealer.status}</Badge>}
      />

      <Panel className="p-6">
        <dl className="grid gap-x-8 gap-y-4 sm:grid-cols-2 lg:grid-cols-3">
          {fields.map((field) => (
            <div key={field.label}>
              <dt className="text-xs font-medium uppercase tracking-wide text-ink-400">
                {field.label}
              </dt>
              <dd className="mt-0.5 text-sm text-ink-900">{field.value}</dd>
            </div>
          ))}
        </dl>
      </Panel>
    </div>
  );
}
