import Link from 'next/link';
import type { Metadata } from 'next';
import { notFound } from 'next/navigation';

import {
  getChart,
  getGroupOptions,
  getLedger,
  getOpeningBills,
  getOpeningEntered,
  type LedgerKind,
  type LedgerRow,
} from '@/server/services/accounting/ledger-master-service';
import { getCustomer } from '@/server/services/customers/customer-service';
import { getMasterRecord } from '@/server/services/masters/masters-service';
import { requireTenantContext } from '@/server/auth/tenant-context';
import { NotFoundError } from '@/server/errors';
import { PageHeader } from '@/components/data-table/data-table';
import { Panel } from '@/components/ui/panel';
import { Badge } from '@/components/ui/badge';
import { ModifyAccountForm, OpeningBalanceForm } from '@/components/accounting/ledger-master-forms';
import { AccountStatusToggle } from '@/components/accounting/account-form';
import { CustomerForm } from '@/components/forms/customer-form';
import { MasterForm } from '@/components/forms/master-form';
import { SUPPLIER_FIELD_GROUPS } from '@/components/forms/supplier-fields';
import { formatDate, formatDrCr } from '@/lib/format';

export const metadata: Metadata = { title: 'Modify ledger' };
export const dynamic = 'force-dynamic';

const KINDS: Record<string, LedgerKind> = {
  account: 'ACCOUNT',
  customer: 'CUSTOMER',
  supplier: 'SUPPLIER',
  'finance-company': 'FINANCE_COMPANY',
};

async function findLedger(kind: LedgerKind, id: string): Promise<LedgerRow | null> {
  try {
    return await getLedger(kind, id);
  } catch (error) {
    if (error instanceof NotFoundError) return null;
    throw error;
  }
}

function statementHref(kind: LedgerKind, id: string): string {
  switch (kind) {
    case 'CUSTOMER': return `/accounting/customer-ledger?customer=${id}`;
    case 'SUPPLIER': return `/accounting/supplier-ledger?supplier=${id}`;
    case 'FINANCE_COMPANY': return `/finance/ledger?company=${id}`;
    default: return `/accounting/ledger?account=${id}`;
  }
}

function Figure({ label, value }: { readonly label: string; readonly value: string }) {
  return (
    <div>
      <p className="text-[11px] font-medium uppercase tracking-wide text-ink-500">{label}</p>
      <p className="numeric text-sm font-semibold text-ink-900">{value}</p>
    </div>
  );
}

/**
 * Modify one ledger — BUSY's Masters → Account → Modify. Name, alias, code and
 * group for an account or a group; the party's own form for a customer or a
 * supplier; and the opening balance for any ledger that takes one here.
 */
export default async function ModifyLedgerPage({
  params,
}: {
  params: Promise<{ kind: string; id: string }>;
}) {
  const { kind: kindParam, id } = await params;
  const kind = KINDS[kindParam];
  if (!kind) notFound();

  const context = await requireTenantContext();
  const canPost = context.permissions.has('accounting.journals.post');
  const canManage = context.permissions.has('accounting.coa.manage');

  const [chart, ledger] = await Promise.all([getChart(), findLedger(kind, id)]);
  const account = kind === 'ACCOUNT' ? chart.find((a) => a.id === id) : undefined;
  if (kind === 'ACCOUNT' ? !account : !ledger) notFound();

  const groups = kind === 'ACCOUNT' ? await getGroupOptions(chart) : [];
  const opening = account?.isGroup ? 0 : await getOpeningEntered(kind, id);
  const title = account?.name ?? ledger?.name ?? 'Ledger';
  const parentName = account ? chart.find((a) => a.id === account.parentId)?.name : ledger?.groupName;

  return (
    <div className="mx-auto max-w-4xl space-y-4">
      <PageHeader
        title={`Modify ${account?.isGroup ? 'group' : 'ledger'}: ${title}`}
        description={[parentName, account?.type.toLowerCase() ?? ledger?.type.toLowerCase()].filter(Boolean).join(' · ')}
        action={
          <div className="flex items-center gap-3 text-sm">
            {!account?.isGroup && (
              <Link href={statementHref(kind, id)} className="text-brand-700 hover:underline">Statement</Link>
            )}
            <Link href={account?.isGroup ? '/accounting/ledger-groups' : '/accounting/ledgers'} className="text-ink-500 hover:underline">
              Back
            </Link>
          </div>
        }
      />

      {ledger && (
        <Panel className="flex flex-wrap gap-8 p-5">
          <Figure label="Opening" value={formatDrCr(ledger.opening)} />
          <Figure label="Closing" value={formatDrCr(ledger.closing)} />
          <div className="flex items-center gap-2">
            {account?.isSystem && <Badge variant="neutral">System</Badge>}
            {ledger.status !== 'ACTIVE' && <Badge variant="warning">{ledger.status.toLowerCase()}</Badge>}
          </div>
        </Panel>
      )}

      {account && (
        <Panel className="p-5">
          <h2 className="mb-4 text-sm font-semibold text-ink-900">{account.isGroup ? 'Group' : 'Ledger'}</h2>
          <ModifyAccountForm
            account={{
              id: account.id, code: account.code, name: account.name, alias: account.alias, type: account.type,
              parentId: account.parentId, isSystem: account.isSystem, isGroup: account.isGroup,
            }}
            groups={groups}
            canManage={canManage}
            hasPostings={Boolean(ledger && (ledger.closing !== 0 || ledger.opening !== 0))}
          />
          {canManage && !account.isGroup && (
            <div className="mt-4 flex items-center justify-between border-t border-ink-100 pt-4">
              <p className="text-xs text-ink-500">A ledger that still carries a balance cannot be deactivated.</p>
              <AccountStatusToggle accountId={account.id} status={account.status} />
            </div>
          )}
        </Panel>
      )}

      {kind === 'CUSTOMER' && <CustomerPanel id={id} />}
      {kind === 'SUPPLIER' && <SupplierPanel id={id} canEdit={context.permissions.has('masters.suppliers.manage')} />}
      {kind === 'FINANCE_COMPANY' && (
        <Panel className="p-5 text-sm text-ink-600">
          The company&apos;s details, commission and ledger account are kept on the finance company master.{' '}
          <Link href={`/finance/companies/${id}/edit`} className="text-brand-700 hover:underline">Modify the finance company</Link>.
        </Panel>
      )}

      {!account?.isGroup && canPost && (
        <Panel className="p-5">
          <h2 className="mb-1 text-sm font-semibold text-ink-900">Opening balance</h2>
          <p className="mb-4 text-xs text-ink-500">
            Now {formatDrCr(opening)}. Saving posts only the difference against Opening Balance Equity — posted journals are never edited.
          </p>
          <OpeningBalanceForm kind={kind} id={id} current={opening} />
          {(kind === 'CUSTOMER' || kind === 'SUPPLIER') && <OpeningBillsList kind={kind} id={id} />}
        </Panel>
      )}
    </div>
  );
}

async function CustomerPanel({ id }: { readonly id: string }) {
  const context = await requireTenantContext();
  if (!context.permissions.has('customers.edit')) {
    return <Panel className="p-5 text-sm text-ink-600">Your role cannot change customer details.</Panel>;
  }
  const customer = await getCustomer(id);
  return (
    <CustomerForm
      mode="edit"
      customerId={customer.id}
      customerCode={customer.customer_code}
      branches={context.accessibleBranches.map((b) => ({ id: b.id, name: b.name }))}
      defaultValues={{
        name: customer.name,
        customer_type: customer.customer_type,
        mobile: customer.mobile,
        alternate_mobile: customer.alternate_mobile ?? '',
        email: customer.email ?? '',
        address_line1: customer.address_line1 ?? '',
        address_line2: customer.address_line2 ?? '',
        city: customer.city ?? '',
        state: customer.state ?? '',
        state_code: customer.state_code ?? '',
        pincode: customer.pincode ?? '',
        gstin: customer.gstin ?? '',
        pan: customer.pan ?? '',
        origin_branch_id: customer.origin_branch_id ?? '',
        notes: customer.notes ?? '',
        status: customer.status,
      }}
    />
  );
}

async function SupplierPanel({ id, canEdit }: { readonly id: string; readonly canEdit: boolean }) {
  if (!canEdit) {
    return <Panel className="p-5 text-sm text-ink-600">Your role cannot change supplier details.</Panel>;
  }
  const record = await getMasterRecord('supplier', id);
  if (!record) notFound();
  return (
    <MasterForm
      kind="supplier"
      mode="edit"
      recordId={id}
      groups={SUPPLIER_FIELD_GROUPS}
      defaultValues={record}
      returnTo={`/accounting/ledgers/supplier/${id}`}
      title="supplier"
    />
  );
}

async function OpeningBillsList({ kind, id }: { readonly kind: 'CUSTOMER' | 'SUPPLIER'; readonly id: string }) {
  const bills = await getOpeningBills(kind, id);
  return (
    <div className="mt-5 border-t border-ink-100 pt-4">
      <div className="mb-2 flex items-center justify-between">
        <h3 className="text-xs font-semibold uppercase tracking-wide text-ink-500">Opening bills</h3>
        <Link href="/accounting/opening-balances" className="text-xs text-brand-700 hover:underline">Enter bill-wise</Link>
      </div>
      {bills.length === 0 ? (
        <p className="text-xs text-ink-500">
          No bill-wise opening. Entering the opening as bills lets each one be settled and aged on its own.
        </p>
      ) : (
        <table className="w-full text-sm">
          <thead>
            <tr className="text-[11px] uppercase tracking-wide text-ink-500">
              <th className="py-1 text-left font-semibold">Bill</th>
              <th className="py-1 text-left font-semibold">Dated</th>
              <th className="py-1 text-right font-semibold">Amount</th>
              <th className="py-1 text-right font-semibold">Still open</th>
            </tr>
          </thead>
          <tbody>
            {bills.map((b) => (
              <tr key={b.lineId} className="border-t border-ink-100">
                <td className="py-1.5 font-mono text-xs">{b.reference}</td>
                <td className="py-1.5 text-ink-600">{formatDate(b.billDate)}</td>
                <td className="numeric py-1.5">{b.amount.toLocaleString('en-IN', { minimumFractionDigits: 2 })}</td>
                <td className="numeric py-1.5">{b.outstanding ? b.outstanding.toLocaleString('en-IN', { minimumFractionDigits: 2 }) : '—'}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}
