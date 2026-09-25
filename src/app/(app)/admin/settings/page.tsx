import type { Metadata } from 'next';

import {
  DEALER_SWITCHES,
  getDealerSwitches,
  getSettings,
  type SchemaStatus,
} from '@/server/services/org/org-service';
import { requireTenantContext } from '@/server/auth/tenant-context';
import { DealerSwitches } from '@/components/admin/dealer-switches';
import { ActionForm } from '@/components/forms/action-form';
import { getQuickBillTaxCodes, HEAD_LABEL, type BillHead } from '@/server/services/billing/quick-bill-service';
import { saveQuickBillTaxCodesAction } from '@/server/services/billing/quick-bill-actions';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Panel, PanelContent, PanelHeader, PanelTitle } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import type { Tables } from '@/types/database.types';
import { formatDateTime } from '@/lib/format';

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
  const [{ settings, sequences, schema }, switches, context] = await Promise.all([
    getSettings(),
    getDealerSwitches(),
    requireTenantContext(),
  ]);
  const quickBill = context.dealerId && context.permissions.has('admin.settings.manage')
    ? await getQuickBillTaxCodes() : null;

  return (
    <div className="space-y-5">
      {context.dealerId && (
        <Panel>
          <PanelHeader>
            <PanelTitle>Controls</PanelTitle>
          </PanelHeader>
          <PanelContent>
            <DealerSwitches
              switches={DEALER_SWITCHES}
              values={switches}
              canManage={context.permissions.has('admin.settings.manage')}
            />
          </PanelContent>
        </Panel>
      )}

      {quickBill && (
        <Panel>
          <PanelHeader>
            <PanelTitle>GST on service and counter bills</PanelTitle>
          </PanelHeader>
          <PanelContent>
            <p className="mb-3 text-xs text-ink-500">
              The cashier types what the customer pays; GST is worked out of that amount at the code chosen here
              for each head. A change applies to bills made from now on — earlier bills keep their tax.
            </p>
            <ActionForm action={saveQuickBillTaxCodesAction} submitLabel="Save GST codes" columns={3} resetOnSuccess={false}
              fields={(Object.keys(HEAD_LABEL) as BillHead[]).map((head) => ({
                name: head, label: HEAD_LABEL[head], type: 'select' as const, required: true,
                defaultValue: quickBill.codes[head], options: quickBill.options,
              }))} />
          </PanelContent>
        </Panel>
      )}

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

      <SchemaPanel schema={schema} />
    </div>
  );
}

/**
 * Whether the database has caught up with the code (spec §59).
 *
 * The application deploys on push while migrations are applied to Supabase by
 * hand, so a running build can expect tables that are not there yet. Before this
 * panel the only symptom was a PostgREST error about a function signature, shown
 * to whoever pressed the button and to nobody who could act on it.
 *
 * Three states, deliberately distinct. "Not recorded" is not folded into
 * "behind": a database applied before 0059 cannot say what it has, and claiming
 * it is current would be the exact false reassurance this replaces.
 */
function SchemaPanel({ schema }: { readonly schema: SchemaStatus }) {
  const behind = schema.tracked && schema.missing.length > 0;

  return (
    <Panel>
      <PanelHeader>
        <div className="flex items-center gap-2">
          <PanelTitle>Database schema</PanelTitle>
          {!schema.tracked ? (
            <Badge variant="warning">Not recorded</Badge>
          ) : behind ? (
            <Badge variant="danger">
              {schema.missing.length} migration{schema.missing.length === 1 ? '' : 's'} behind
            </Badge>
          ) : (
            <Badge variant="positive">Up to date</Badge>
          )}
        </div>
      </PanelHeader>
      <PanelContent>
        <dl className="grid gap-x-8 gap-y-3 sm:grid-cols-3">
          <div>
            <dt className="text-xs font-medium uppercase tracking-wide text-ink-400">
              Application expects
            </dt>
            <dd className="mt-0.5 font-mono text-sm text-ink-900">{schema.expected}</dd>
          </div>
          <div>
            <dt className="text-xs font-medium uppercase tracking-wide text-ink-400">
              Database reports
            </dt>
            <dd className="mt-0.5 font-mono text-sm text-ink-900">{schema.applied ?? '—'}</dd>
          </div>
          <div>
            <dt className="text-xs font-medium uppercase tracking-wide text-ink-400">
              Last applied
            </dt>
            <dd className="mt-0.5 text-sm text-ink-900">
              {schema.appliedAt ? formatDateTime(schema.appliedAt) : '—'}
            </dd>
          </div>
        </dl>

        {behind && (
          <div className="mt-4 rounded-lg border border-danger-200 bg-danger-50 p-3">
            <p className="text-sm font-medium text-danger-700">
              This database is missing {schema.missing.length} migration
              {schema.missing.length === 1 ? '' : 's'}.
            </p>
            <p className="mt-1 text-sm text-danger-700">
              Screens that depend on {schema.missing.length === 1 ? 'it' : 'them'} will fail or
              degrade until {schema.missing.length === 1 ? 'it is' : 'they are'} applied. Bundle what
              is missing with{' '}
              <code className="font-mono text-xs">
                FROM={schema.missing[0]} npm run db:incremental
              </code>{' '}
              and run it against the database.
            </p>
            <p className="mt-2 font-mono text-xs text-danger-700">{schema.missing.join(', ')}</p>
          </div>
        )}

        {!schema.tracked && (
          <div className="mt-4 rounded-lg border border-warning-200 bg-warning-50 p-3">
            <p className="text-sm text-warning-700">
              This database was applied before migration 0059, which is the one that introduced
              version tracking, so it cannot report what it has. Applying 0059 records everything up
              to it and this panel starts answering.
            </p>
          </div>
        )}
      </PanelContent>
    </Panel>
  );
}
