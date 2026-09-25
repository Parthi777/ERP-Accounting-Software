import Link from 'next/link';
import type { Metadata } from 'next';

import {
  getTdsBankOptions,
  getTdsRegister,
  getTdsSetup,
  PAYEE_TYPES,
  type TdsRegisterRow,
  type TdsSection,
} from '@/server/services/accounting/tds-service';
import {
  addSectionAction,
  endSectionAction,
  reviewSectionAction,
  saveDeductorAction,
  savePayeeAction,
} from '@/server/services/accounting/tds-actions';
import { requirePermission, requireTenantContext } from '@/server/auth/tenant-context';
import { DataTable, PageHeader, type Column } from '@/components/data-table/data-table';
import { Panel, PanelContent, PanelHeader, PanelTitle } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { Input } from '@/components/ui/input';
import { Button } from '@/components/ui/button';
import { ActionForm } from '@/components/forms/action-form';
import { TdsRemittanceForm } from '@/components/accounting/tds-remittance-form';
import { formatDate } from '@/lib/format';
import { rangeInYear } from '@/lib/period';
import { cn } from '@/lib/utils';

export const metadata: Metadata = { title: 'TDS' };
export const dynamic = 'force-dynamic';

const inr = new Intl.NumberFormat('en-IN', { style: 'currency', currency: 'INR', minimumFractionDigits: 2 });
const money = (n: number | null) => (n === null ? '—' : inr.format(n));
const ACT: Record<string, string> = { IT_1961: 'IT Act 1961', IT_2025: 'IT Act 2025' };
const BASIS: Record<string, string> = {
  THIS_BILL: 'Deduct from the bill that crosses it',
  WHOLE_AGGREGATE: 'Also catch up the year’s earlier bills',
  EXCESS_ONLY: 'Only on the amount above it',
};
const RATE_BASIS: Record<string, string> = {
  SECTION: 'section rate', NO_PAN: 'no PAN', CERTIFICATE: 'certificate', BELOW_THRESHOLD: 'below threshold',
};

const TABS = [
  { key: 'setup', label: 'Sections' },
  { key: 'payees', label: 'Payees' },
  { key: 'register', label: 'Deductions & deposits' },
] as const;

/**
 * TDS (F61–F67). Sections are entered and reviewed by the accountant — none
 * ships with the product; payees carry their section, legal status, PAN check
 * and any lower-deduction certificate; bills deduct when posted; deposits made
 * at the bank are recorded against the deductions. Returns are filed outside.
 */
export default async function TdsPage({ searchParams }: { searchParams: Promise<{ view?: string; from?: string; to?: string }> }) {
  await requirePermission('accounting.tds.manage');
  const context = await requireTenantContext();
  const params = await searchParams;
  const view = TABS.some((t) => t.key === params.view) ? params.view! : 'setup';
  const { from, to } = rangeInYear(context.activeFinancialYear, params.from, params.to);

  const [setup, register, banks] = await Promise.all([
    getTdsSetup(),
    view === 'register' ? getTdsRegister(from, to) : Promise.resolve(null),
    view === 'register' ? getTdsBankOptions() : Promise.resolve([]),
  ]);
  const codes = [...new Set(setup.sections.map((s) => s.code))];

  const sectionColumns: Column<TdsSection>[] = [
    { key: 'code', header: 'Code', render: (s) => <span className="font-mono text-xs">{s.code}</span> },
    {
      key: 'ref', header: 'Section',
      render: (s) => (
        <span className="flex flex-col">
          <span className="text-ink-800">{s.sectionRef} <span className="text-[11px] text-ink-400">{ACT[s.act]}</span></span>
          <span className="text-[11px] text-ink-500">{s.description}{s.payeeTypes && ` · ${s.payeeTypes.join(', ').toLowerCase()}`}</span>
        </span>
      ),
    },
    { key: 'rate', header: 'Rate', numeric: true, render: (s) => `${s.rate}%${s.rateWithoutPan !== null ? ` (no PAN ${s.rateWithoutPan}%)` : ''}` },
    {
      key: 'thr', header: 'Thresholds',
      render: (s) => (
        <span className="text-xs text-ink-600">
          single {money(s.singleThreshold)} · year {money(s.aggregateThreshold)}
          <span className="block text-[11px] text-ink-400">{BASIS[s.thresholdBasis]}</span>
        </span>
      ),
    },
    { key: 'dates', header: 'In force', render: (s) => <span className="text-xs">{formatDate(s.effectiveFrom)} – {s.effectiveTo ? formatDate(s.effectiveTo) : 'open'}</span> },
    { key: 'src', header: 'Source', render: (s) => <span className="text-[11px] text-ink-500">{s.sourceNote}</span> },
    {
      key: 'act', header: '',
      render: (s) => s.reviewed ? (
        s.effectiveTo ? <Badge variant="neutral">ended</Badge> : (
          <details>
            <summary className="cursor-pointer text-xs text-brand-700"><Badge variant="positive">reviewed</Badge> End…</summary>
            <div className="mt-2 w-48">
              <ActionForm fields={[{ name: 'effectiveTo', label: 'Last day in force', type: 'date', required: true }]}
                fixed={{ id: s.id }} action={endSectionAction} submitLabel="End section" columns={1} />
            </div>
          </details>
        )
      ) : (
        <div className="w-36">
          <ActionForm fields={[]} fixed={{ id: s.id }} action={reviewSectionAction} submitLabel="Mark reviewed" columns={1}
            confirm="Have you checked this rate, threshold and date against the Act or the department's notification?" />
        </div>
      ),
    },
  ];

  const registerColumns: Column<TdsRegisterRow>[] = [
    { key: 'date', header: 'Bill date', render: (r) => formatDate(r.billDate) },
    { key: 'bill', header: 'Bill', render: (r) => <span className="font-mono text-xs">{r.billNumber}</span> },
    { key: 'payee', header: 'Payee', render: (r) => <span>{r.supplierName}<span className="block text-[11px] text-ink-400">{r.pan ?? 'no PAN'}</span></span> },
    { key: 'sec', header: 'Section', render: (r) => <span className="text-xs">{r.sectionRef}<span className="block text-[11px] text-ink-400">{ACT[r.act]}</span></span> },
    { key: 'base', header: 'Bill value', numeric: true, render: (r) => inr.format(r.base) },
    { key: 'ded', header: 'Deducted on', numeric: true, render: (r) => inr.format(r.deductibleBase) },
    { key: 'rate', header: 'Rate', numeric: true, render: (r) => <span>{r.rate}%<span className="block text-[11px] text-ink-400">{RATE_BASIS[r.rateBasis]}</span></span> },
    { key: 'amt', header: 'TDS', numeric: true, render: (r) => <span className="font-semibold">{inr.format(r.amount)}</span> },
    {
      key: 'dep', header: 'Deposit',
      render: (r) => r.status === 'CANCELLED' ? <Badge variant="neutral">cancelled</Badge>
        : r.challan ? <span className="text-xs">{r.challan}<span className="block text-[11px] text-ink-400">{formatDate(r.depositDate)}</span></span>
        : r.amount > 0 ? <Badge variant="warning">not deposited</Badge> : <span className="text-ink-400">—</span>,
    },
  ];

  return (
    <div className="space-y-4">
      <PageHeader title="TDS" description="Tax deducted at source on supplier bills. Rates are entered and reviewed here — none are built in. Returns are prepared and filed outside this system." />

      <nav className="flex gap-1 text-sm" aria-label="Views">
        {TABS.map((t) => (
          <Link key={t.key} href={`/accounting/tds?view=${t.key}`}
            className={cn('rounded-lg px-3 py-1.5', view === t.key ? 'bg-brand-50 font-medium text-brand-800' : 'text-ink-600 hover:bg-ink-50')}>
            {t.label}
          </Link>
        ))}
      </nav>

      {view === 'setup' && (
        <>
          <Panel>
            <PanelHeader><PanelTitle>Deductor</PanelTitle></PanelHeader>
            <PanelContent>
              <ActionForm action={saveDeductorAction} submitLabel="Save" columns={3} resetOnSuccess={false}
                fields={[
                  { name: 'tan', label: 'TAN', defaultValue: setup.deductor.tan ?? '', placeholder: 'CHES12345A' },
                  { name: 'enabled', label: 'Deduct TDS on supplier bills', type: 'checkbox', defaultValue: String(setup.deductor.enabled) },
                ]} />
            </PanelContent>
          </Panel>

          <DataTable columns={sectionColumns} rows={setup.sections} getRowKey={(s) => s.id} caption="TDS sections"
            emptyMessage="No sections entered. Add each section you deduct under, with the rate from the Act." />

          <Panel>
            <PanelHeader><PanelTitle>Enter a section</PanelTitle></PanelHeader>
            <PanelContent>
              <p className="mb-3 text-xs text-ink-500">
                The Income-tax Act, 2025 applies where the earlier of credit or payment is on or after 1 April 2026; its TDS
                provisions sit under section 393 (the department&apos;s example: 194C is 393(1) Table Sl. No. 6(i)). Enter
                one row per Act and period, with the source you took the rate from. A different rate for a payee type is its
                own row under the same code. Rates are never edited: end a row and enter the next.
              </p>
              <ActionForm action={addSectionAction} submitLabel="Enter section" columns={4}
                fields={[
                  { name: 'code', label: 'Code', required: true, placeholder: 'CONTRACT' },
                  { name: 'act', label: 'Act', type: 'select', required: true, defaultValue: 'IT_2025',
                    options: [{ value: 'IT_2025', label: 'Income-tax Act, 2025' }, { value: 'IT_1961', label: 'Income-tax Act, 1961' }] },
                  { name: 'sectionRef', label: 'Section reference', required: true, placeholder: '393(1) Table Sl. No. 6(i)' },
                  { name: 'description', label: 'Description', placeholder: 'Payment to contractors' },
                  { name: 'rate', label: 'Rate %', type: 'number', required: true, step: '0.001' },
                  { name: 'rateWithoutPan', label: 'Rate without PAN %', type: 'number', step: '0.001' },
                  { name: 'singleThreshold', label: 'Single bill above ₹', type: 'number' },
                  { name: 'aggregateThreshold', label: 'Year total above ₹', type: 'number' },
                  { name: 'thresholdBasis', label: 'When the year total is crossed', type: 'select', defaultValue: 'THIS_BILL',
                    options: Object.entries(BASIS).map(([value, label]) => ({ value, label })) },
                  { name: 'payeeType', label: 'Only for payee type', type: 'select',
                    options: PAYEE_TYPES.map((p) => ({ value: p.value, label: p.label })) },
                  { name: 'effectiveFrom', label: 'In force from', type: 'date', required: true },
                  { name: 'effectiveTo', label: 'In force to', type: 'date' },
                  { name: 'sourceNote', label: 'Source', required: true, wide: true, placeholder: 'Act, section, notification or page read, and the date' },
                ]} />
            </PanelContent>
          </Panel>
        </>
      )}

      {view === 'payees' && (
        <Panel>
          <PanelHeader><PanelTitle>Payees</PanelTitle></PanelHeader>
          <PanelContent>
            <p className="mb-3 text-xs text-ink-500">
              The payee type is the supplier&apos;s legal status as documented — never guessed from the name. A lower-deduction
              certificate applies between its dates and up to its limit.
            </p>
            <ul className="divide-y divide-ink-100">
              {setup.payees.map((p) => (
                <li key={p.id} className="py-2">
                  <details>
                    <summary className="flex cursor-pointer flex-wrap items-center gap-2 text-sm">
                      <span className="font-medium text-ink-800">{p.name}</span>
                      <span className="font-mono text-[11px] text-ink-400">{p.code}</span>
                      {p.sectionCode ? <Badge variant="info">{p.sectionCode}</Badge> : <span className="text-xs text-ink-400">no TDS</span>}
                      {p.sectionCode && !p.panVerified && <Badge variant="warning">PAN not verified</Badge>}
                      {p.ldcNumber && <Badge variant="neutral">certificate {p.ldcRate}%</Badge>}
                    </summary>
                    <div className="mt-3">
                      <ActionForm action={savePayeeAction} submitLabel="Save TDS profile" columns={4} resetOnSuccess={false}
                        fixed={{ supplierId: p.id }}
                        fields={[
                          { name: 'sectionCode', label: 'Section', type: 'select', defaultValue: p.sectionCode ?? '',
                            options: codes.map((c) => ({ value: c, label: c })) },
                          { name: 'payeeType', label: 'Payee type', type: 'select', defaultValue: p.payeeType ?? '',
                            options: PAYEE_TYPES.map((t) => ({ value: t.value, label: t.label })) },
                          { name: 'panVerified', label: `PAN verified${p.pan ? ` (${p.pan})` : ' — none on file'}`, type: 'checkbox',
                            defaultValue: String(p.panVerified) },
                          { name: 'ldcNumber', label: 'Certificate no.', defaultValue: p.ldcNumber ?? '' },
                          { name: 'ldcRate', label: 'Certificate rate %', type: 'number', step: '0.001', defaultValue: p.ldcRate?.toString() ?? '' },
                          { name: 'ldcValidFrom', label: 'Valid from', type: 'date', defaultValue: p.ldcValidFrom ?? '' },
                          { name: 'ldcValidTo', label: 'Valid to', type: 'date', defaultValue: p.ldcValidTo ?? '' },
                          { name: 'ldcLimit', label: 'Up to ₹', type: 'number', defaultValue: p.ldcLimit?.toString() ?? '' },
                        ]} />
                    </div>
                  </details>
                </li>
              ))}
            </ul>
          </PanelContent>
        </Panel>
      )}

      {view === 'register' && register && (
        <>
          <form className="flex flex-wrap items-center gap-2">
            <input type="hidden" name="view" value="register" />
            <Input type="date" name="from" defaultValue={from} className="w-44" aria-label="From" />
            <Input type="date" name="to" defaultValue={to} className="w-44" aria-label="To" />
            <Button type="submit" variant="secondary" size="sm">Show</Button>
          </form>

          <Panel className={cn('p-4 text-sm', register.control.difference !== 0 && 'ring-2 ring-danger-300')}>
            2745 TDS Payable — Suppliers <span className="numeric font-semibold">{inr.format(register.control.ledger)}</span>
            {' '}· deductions not yet deposited <span className="numeric font-semibold">{inr.format(register.control.unremitted)}</span>
            {' '}· {register.control.difference === 0
              ? <Badge variant="positive">agree</Badge>
              : <Badge variant="danger">differ by {inr.format(register.control.difference)}</Badge>}
          </Panel>

          <DataTable columns={registerColumns} rows={register.rows} getRowKey={(r) => r.id} caption="TDS register"
            emptyMessage="No bills in this period had a TDS section." maxHeight="36rem" />

          <Panel>
            <PanelHeader><PanelTitle>Record a deposit</PanelTitle></PanelHeader>
            <PanelContent>
              <p className="mb-3 text-xs text-ink-500">
                For a deposit already made at the bank. It records the payment and ties it to the deductions; it does not pay,
                and filing the return is done outside this system.
              </p>
              <TdsRemittanceForm banks={banks}
                deductions={register.rows
                  .filter((r) => r.status === 'POSTED' && !r.challan && r.amount > 0)
                  .map((r) => ({ id: r.id, amount: r.amount, label: `${formatDate(r.billDate)} · ${r.billNumber} · ${r.supplierName} · ${r.sectionRef}` }))} />
            </PanelContent>
          </Panel>
        </>
      )}
    </div>
  );
}
