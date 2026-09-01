import type { Metadata } from 'next';

import { getSettings } from '@/server/services/org/org-service';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Panel, PanelContent, PanelHeader, PanelTitle } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import type { Tables } from '@/types/database.types';

export const metadata: Metadata = { title: 'Settings' };
export const dynamic = 'force-dynamic';

const settingColumns: Column<Tables<'system_settings'>>[] = [
  {
    key: 'key',
    header: 'Key',
    render: (row) => <code className="font-mono text-xs text-ink-700">{row.key}</code>,
  },
  {
    key: 'value',
    header: 'Value',
    render: (row) => (
      <code className="rounded bg-ink-100 px-1.5 py-0.5 font-mono text-xs text-brand-700">
        {JSON.stringify(row.value)}
      </code>
    ),
  },
  {
    key: 'description',
    header: 'Description',
    render: (row) => <span className="text-ink-600">{row.description ?? '—'}</span>,
  },
  {
    key: 'scope',
    header: 'Scope',
    render: (row) => (
      <Badge variant={row.dealer_id ? 'info' : 'neutral'}>
        {row.dealer_id ? 'Dealer' : 'Platform'}
      </Badge>
    ),
  },
];

const sequenceColumns: Column<Tables<'document_sequences'>>[] = [
  {
    key: 'doc_type',
    header: 'Document type',
    render: (row) => <span className="font-medium text-ink-800">{row.doc_type}</span>,
  },
  {
    key: 'sample',
    header: 'Next number',
    render: (row) => (
      <code className="font-mono text-xs text-brand-700">
        {row.prefix}-{row.financial_year}-
        {String(row.last_number + 1).padStart(row.padding, '0')}
      </code>
    ),
  },
  { key: 'year', header: 'Year', render: (row) => row.financial_year },
  {
    key: 'scope',
    header: 'Scope',
    render: (row) => (row.branch_id ? 'Per branch' : 'Dealer-wide'),
  },
  { key: 'issued', header: 'Issued', numeric: true, render: (row) => row.last_number },
];

export default async function SettingsPage() {
  const { settings, sequences } = await getSettings();

  return (
    <div className="space-y-5">
      <div>
        <PageHeader
          title="Settings"
          description="Configuration held as data rather than code. A dealer-scoped key overrides the platform default of the same name."
          count={settings.length}
        />
        <DataTable
          columns={settingColumns}
          rows={settings}
          getRowKey={(row) => row.id}
          caption="System settings"
          emptyMessage="No settings are visible to your account."
        />
      </div>

      <div>
        <div className="mb-3">
          <h2 className="text-base font-semibold text-ink-900">Document sequences</h2>
          <p className="text-sm text-ink-500">
            Financial document numbers are issued by the database under a row lock, never generated
            in the browser.
          </p>
        </div>
        <DataTable
          columns={sequenceColumns}
          rows={sequences}
          getRowKey={(row) => row.id}
          caption="Document sequences"
          emptyMessage="No sequences configured."
        />
      </div>

      <Panel>
        <PanelHeader>
          <PanelTitle>Phase 1 scope</PanelTitle>
        </PanelHeader>
        <PanelContent>
          <p className="text-sm text-ink-600">
            These values are readable here and editable through the database. Editing screens arrive
            with the modules that consume each setting — accessory allocation with inventory, cash
            closing with the cash book, and so on.
          </p>
        </PanelContent>
      </Panel>
    </div>
  );
}
