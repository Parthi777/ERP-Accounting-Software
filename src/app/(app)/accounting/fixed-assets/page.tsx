import type { Metadata } from 'next';

import { getAssetAccounts, getAssetRegister } from '@/server/services/assets/asset-service';
import { disposeAssetAction, registerAssetAction, runDepreciationAction } from '@/server/services/assets/asset-actions';
import { requireTenantContext } from '@/server/auth/tenant-context';
import { PageHeader } from '@/components/data-table/data-table';
import { Panel, PanelContent, PanelHeader, PanelTitle, SolidPanel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { ActionForm } from '@/components/forms/action-form';
import { formatINR, ZERO, add, type Paise } from '@/lib/money';
import { formatDate } from '@/lib/format';

export const metadata: Metadata = { title: 'Fixed Assets' };
export const dynamic = 'force-dynamic';

/**
 * Fixed asset register and depreciation — checklist §02, §09 (0082).
 * Registering posts nothing; running a month's depreciation and disposing do.
 */
export default async function FixedAssetsPage() {
  const context = await requireTenantContext();
  const today = new Date().toISOString().slice(0, 10);
  const [assets, accounts] = await Promise.all([getAssetRegister(today), getAssetAccounts()]);
  const canManage = context.permissions.has('assets.manage');
  const total = (k: 'cost' | 'accumulated' | 'netBookValue') =>
    assets.filter((a) => a.status === 'ACTIVE').reduce<Paise>((s, a) => add(s, a[k]), ZERO);
  const th = 'px-4 py-2.5 text-[11px] font-semibold uppercase tracking-wide text-ink-500';

  return (
    <div className="space-y-5">
      <PageHeader title="Fixed Assets" description="The asset register, monthly depreciation, and disposals." count={assets.length} />

      {canManage && (
        <div className="grid gap-5 lg:grid-cols-3">
          <Panel className="lg:col-span-2">
            <PanelHeader><PanelTitle>Register an asset</PanelTitle></PanelHeader>
            <PanelContent>
              <ActionForm action={registerAssetAction} submitLabel="Register asset" fields={[
                { name: 'name', label: 'Asset', required: true, placeholder: 'Service ramp' },
                { name: 'accountId', label: 'Asset account', type: 'select', required: true, options: accounts.map((a) => ({ value: a.id, label: a.label })) },
                { name: 'category', label: 'Category', placeholder: 'Computers' },
                { name: 'acquiredOn', label: 'Acquired on', type: 'date', required: true },
                { name: 'cost', label: 'Cost (₹)', type: 'number', required: true, hint: 'Already in the ledger from its bill — registering posts nothing.' },
                { name: 'salvage', label: 'Salvage value (₹)', type: 'number', defaultValue: '0' },
                { name: 'method', label: 'Method', type: 'select', required: true, defaultValue: 'SLM', options: [
                  { value: 'SLM', label: 'Straight line' }, { value: 'WDV', label: 'Written-down value' } ] },
                { name: 'lifeMonths', label: 'Useful life (months, SLM)', type: 'number', step: '1', placeholder: '60' },
                { name: 'wdvRate', label: 'Annual rate % (WDV)', type: 'number', placeholder: '15' },
              ]} />
            </PanelContent>
          </Panel>
          <Panel>
            <PanelHeader><PanelTitle>Run depreciation</PanelTitle></PanelHeader>
            <PanelContent>
              <ActionForm action={runDepreciationAction} submitLabel="Post depreciation" columns={1}
                confirm="Post this month's depreciation for every active asset?"
                fields={[{ name: 'month', label: 'Month', type: 'month', required: true, defaultValue: today.slice(0, 7),
                  hint: 'One journal per branch. An asset is charged once a month at most; running again charges only what was missed.' }]} />
            </PanelContent>
          </Panel>
        </div>
      )}

      <SolidPanel className="overflow-hidden">
        <div className="table-sticky overflow-auto">
          <table className="w-full border-collapse text-sm">
            <thead><tr>
              <th className={`${th} text-left`}>Asset</th><th className={`${th} text-left`}>Acquired</th>
              <th className={`${th} text-left`}>Method</th><th className={`${th} text-right`}>Cost</th>
              <th className={`${th} text-right`}>Depreciation</th><th className={`${th} text-right`}>Book value</th>
              <th className={`${th} text-left`}>Status</th>
            </tr></thead>
            <tbody>
              {assets.length === 0 ? (
                <tr><td colSpan={7} className="px-4 py-12 text-center text-ink-400">No assets registered yet.</td></tr>
              ) : assets.map((a) => (
                <tr key={a.id} className="border-t border-ink-100 align-top">
                  <td className="px-4 py-2">
                    <span className="font-semibold text-ink-900">{a.code} · {a.name}</span>
                    <span className="block text-[11px] text-ink-500">{a.account} · {a.branch}{a.category ? ` · ${a.category}` : ''}</span>
                    {canManage && a.status === 'ACTIVE' && (
                      <details className="mt-2">
                        <summary className="cursor-pointer text-xs font-semibold text-brand-700">Dispose…</summary>
                        <div className="mt-2 max-w-xl">
                          <ActionForm action={disposeAssetAction} submitLabel="Dispose and post" fixed={{ assetId: a.id }}
                            confirm={`Take ${a.code} off the books? The gain or loss posts now.`}
                            fields={[
                              { name: 'date', label: 'Date', type: 'date', required: true, defaultValue: today },
                              { name: 'proceeds', label: 'Proceeds (₹)', type: 'number', defaultValue: '0' },
                              { name: 'reason', label: 'Reason', required: true, placeholder: 'Sold / scrapped' },
                            ]} />
                        </div>
                      </details>
                    )}
                  </td>
                  <td className="px-4 py-2 text-ink-600">{formatDate(a.acquiredOn)}</td>
                  <td className="px-4 py-2 text-ink-600">{a.method}{a.lastPeriod ? ` · to ${formatDate(a.lastPeriod)}` : ''}</td>
                  <td className="numeric px-4 py-2">{formatINR(a.cost)}</td>
                  <td className="numeric px-4 py-2">{formatINR(a.accumulated)}</td>
                  <td className="numeric px-4 py-2 font-semibold">{formatINR(a.netBookValue)}</td>
                  <td className="px-4 py-2"><Badge variant={a.status === 'ACTIVE' ? 'positive' : 'neutral'}>{a.status}</Badge></td>
                </tr>
              ))}
            </tbody>
            {assets.length > 0 && (
              <tfoot><tr className="border-t-2 border-ink-300 bg-ink-50 font-semibold">
                <td className="px-4 py-3" colSpan={3}>Active assets</td>
                <td className="numeric px-4 py-3">{formatINR(total('cost'))}</td>
                <td className="numeric px-4 py-3">{formatINR(total('accumulated'))}</td>
                <td className="numeric px-4 py-3">{formatINR(total('netBookValue'))}</td>
                <td />
              </tr></tfoot>
            )}
          </table>
        </div>
      </SolidPanel>
    </div>
  );
}
