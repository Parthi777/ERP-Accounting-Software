'use client';

import * as React from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import { Loader2, Save } from 'lucide-react';

import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { Input, Label } from '@/components/ui/input';
import { AmountInput } from '@/components/forms/amount-input';
import { cn } from '@/lib/utils';
import {
  createLedgerAction,
  modifyAccountAction,
  setOpeningBalanceAction,
} from '@/server/services/accounting/ledger-master-actions';

export interface GroupOption {
  readonly id: string;
  readonly code: string;
  readonly name: string;
  readonly type: string;
  readonly depth: number;
  readonly path: string;
  /** Set when the group holds parties, cash or bank rather than plain ledgers. */
  readonly role?: 'DEBTORS' | 'CREDITORS' | 'FINANCIERS' | 'CASH' | 'BANK';
  readonly suggestedCode: string;
}

type Side = 'DR' | 'CR';

function Feedback({ error, notice }: { readonly error: string | null; readonly notice: string | null }) {
  return (
    <>
      {error && <p role="alert" className="rounded-xl bg-danger-50 px-3 py-2 text-sm text-danger-700 sm:col-span-full">{error}</p>}
      {notice && <p className="rounded-xl bg-positive-50 px-3 py-2 text-sm text-positive-700 sm:col-span-full">{notice}</p>}
    </>
  );
}

function GroupSelect({
  id,
  groups,
  value,
  onChange,
  allowTypes,
  disabled,
}: {
  readonly id: string;
  readonly groups: readonly GroupOption[];
  readonly value: string;
  readonly onChange: (value: string) => void;
  /** Only groups of this type — a ledger that has postings keeps its type. */
  readonly allowTypes?: readonly string[];
  readonly disabled?: boolean;
}) {
  return (
    <select id={id} value={value} disabled={disabled} onChange={(e) => onChange(e.target.value)}
      className="field h-10 w-full px-3 text-sm">
      <option value="">Choose a group…</option>
      {groups
        .filter((g) => !allowTypes || allowTypes.includes(g.type))
        .map((g) => (
          <option key={g.id} value={g.id}>
            {'  '.repeat(g.depth)}{g.name}
          </option>
        ))}
    </select>
  );
}

function OpeningFields({
  amount,
  side,
  onAmount,
  onSide,
  idPrefix,
}: {
  readonly amount: string;
  readonly side: Side;
  readonly onAmount: (v: string) => void;
  readonly onSide: (v: Side) => void;
  readonly idPrefix: string;
}) {
  return (
    <div>
      <Label htmlFor={`${idPrefix}-opening`} className="mb-1.5 block">Opening balance</Label>
      <div className="flex gap-2">
        <AmountInput id={`${idPrefix}-opening`} value={amount} placeholder="0.00" onValueChange={onAmount} />
        <select aria-label="Dr or Cr" value={side} onChange={(e) => onSide(e.target.value as Side)}
          className="field h-10 w-20 px-2 text-sm">
          <option value="DR">Dr</option>
          <option value="CR">Cr</option>
        </select>
      </div>
      <p className="mt-1 text-[11px] text-ink-500">Posted against Opening Balance Equity, dated before the first financial year.</p>
    </div>
  );
}

/**
 * Add a ledger or a group — BUSY's Masters → Account → Add. The group decides
 * what "a ledger" is: under Sundry Debtors it is a customer, under Sundry
 * Creditors a supplier, under Cash-in-Hand or Bank Accounts a cash or bank
 * account. Those have their own masters, which the form hands over to.
 */
export function NewLedgerForm({
  groups,
  isGroup = false,
  partyForms,
}: {
  readonly groups: readonly GroupOption[];
  readonly isGroup?: boolean;
  /** The customer and supplier forms, rendered by the server page. */
  readonly partyForms?: { readonly DEBTORS?: React.ReactNode; readonly CREDITORS?: React.ReactNode };
}) {
  const router = useRouter();
  const [groupId, setGroupId] = React.useState('');
  const [name, setName] = React.useState('');
  const [alias, setAlias] = React.useState('');
  const [code, setCode] = React.useState('');
  const [codeTouched, setCodeTouched] = React.useState(false);
  const [amount, setAmount] = React.useState('');
  const [side, setSide] = React.useState<Side>('DR');
  const [error, setError] = React.useState<string | null>(null);
  const [notice, setNotice] = React.useState<string | null>(null);
  const [pending, startTransition] = React.useTransition();

  const group = groups.find((g) => g.id === groupId);
  const role = isGroup ? undefined : group?.role;

  const chooseGroup = (id: string) => {
    setGroupId(id);
    const g = groups.find((x) => x.id === id);
    if (!codeTouched) setCode(g?.suggestedCode ?? '');
    if (g && !amount) setSide(g.type === 'ASSET' || g.type === 'EXPENSE' ? 'DR' : 'CR');
  };

  const submit = (event: React.FormEvent) => {
    event.preventDefault();
    setError(null);
    setNotice(null);
    if (!groupId) return setError('Choose the group it belongs under.');
    if (name.trim().length < 2) return setError('Give it a name.');
    if (!code.trim()) return setError('Give it a code.');
    startTransition(async () => {
      const result = await createLedgerAction({
        name, alias, code, groupId, isGroup, openingAmount: amount, openingSide: side,
      });
      if (!result.ok) {
        setError(result.error ?? 'It could not be added.');
        return;
      }
      setNotice(result.message ?? 'Added.');
      setName(''); setAlias(''); setCode(''); setCodeTouched(false); setAmount('');
      router.refresh();
    });
  };

  return (
    <Panel className="p-5">
      <div className="mb-4 grid gap-4 sm:grid-cols-2">
        <div>
          <Label htmlFor="nl-group" className="mb-1.5 block">
            {isGroup ? 'Under group' : 'Group'}<span className="ml-0.5 text-danger-600">*</span>
          </Label>
          <GroupSelect id="nl-group" groups={groups} value={groupId} onChange={chooseGroup} />
          {group && <p className="mt-1 text-[11px] text-ink-500">{group.path} · {group.type.toLowerCase()}</p>}
        </div>
      </div>

      {role === 'DEBTORS' && (
        <div>
          <p className="mb-3 text-sm text-ink-600">A ledger under {group?.name} is a customer. Their details are kept on the customer master.</p>
          {partyForms?.DEBTORS}
        </div>
      )}
      {role === 'CREDITORS' && (
        <div>
          <p className="mb-3 text-sm text-ink-600">A ledger under {group?.name} is a supplier. Their details are kept on the supplier master.</p>
          {partyForms?.CREDITORS}
        </div>
      )}
      {role === 'FINANCIERS' && (
        <p className="text-sm text-ink-600">
          A financier&apos;s ledger is a finance company. <Link className="text-brand-700 hover:underline" href="/finance/companies/new">Add a finance company</Link>.
        </p>
      )}
      {role === 'CASH' && (
        <p className="text-sm text-ink-600">
          Cash ledgers belong to a branch&apos;s cash book, which carries its own opening. <Link className="text-brand-700 hover:underline" href="/cash-book">Open the cash book</Link>.
        </p>
      )}
      {role === 'BANK' && (
        <p className="text-sm text-ink-600">
          A bank ledger is added with its bank account, so the bank book moves with it. <Link className="text-brand-700 hover:underline" href="/bank">Add a bank account</Link>.
        </p>
      )}

      {!role && (
        <form onSubmit={submit} className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4" noValidate>
          <div className="lg:col-span-2">
            <Label htmlFor="nl-name" className="mb-1.5 block">Name<span className="ml-0.5 text-danger-600">*</span></Label>
            <Input id="nl-name" value={name} onChange={(e) => setName(e.target.value)}
              placeholder={isGroup ? 'Showroom Expenses' : 'Telephone Charges'} />
          </div>
          <div>
            <Label htmlFor="nl-alias" className="mb-1.5 block">Alias</Label>
            <Input id="nl-alias" value={alias} onChange={(e) => setAlias(e.target.value)} placeholder="PHONE" />
          </div>
          <div>
            <Label htmlFor="nl-code" className="mb-1.5 block">Code<span className="ml-0.5 text-danger-600">*</span></Label>
            <Input id="nl-code" className="font-mono uppercase" value={code} maxLength={30}
              onChange={(e) => { setCode(e.target.value); setCodeTouched(true); }} />
          </div>
          {!isGroup && (
            <OpeningFields idPrefix="nl" amount={amount} side={side} onAmount={setAmount} onSide={setSide} />
          )}
          <Feedback error={error} notice={notice} />
          <div className="sm:col-span-full">
            <Button type="submit" disabled={pending}>
              {pending ? <Loader2 className="animate-spin" aria-hidden /> : <Save aria-hidden />}
              {isGroup ? 'Add group' : 'Add ledger'}
            </Button>
          </div>
        </form>
      )}
    </Panel>
  );
}

/**
 * Modify a ledger or a group — name, alias, code and group. A system ledger's
 * code is fixed (posting finds it by code); a type heading stays at the top.
 */
export function ModifyAccountForm({
  account,
  groups,
  canManage,
  hasPostings,
}: {
  readonly account: {
    readonly id: string;
    readonly code: string;
    readonly name: string;
    readonly alias: string | null;
    readonly type: string;
    readonly parentId: string | null;
    readonly isSystem: boolean;
    readonly isGroup: boolean;
  };
  readonly groups: readonly GroupOption[];
  readonly canManage: boolean;
  readonly hasPostings: boolean;
}) {
  const router = useRouter();
  const [name, setName] = React.useState(account.name);
  const [alias, setAlias] = React.useState(account.alias ?? '');
  const [code, setCode] = React.useState(account.code);
  const [groupId, setGroupId] = React.useState(account.parentId ?? '');
  const [error, setError] = React.useState<string | null>(null);
  const [notice, setNotice] = React.useState<string | null>(null);
  const [pending, startTransition] = React.useTransition();
  const heading = account.parentId === null;
  // A group cannot sit beneath itself; the database refuses deeper cycles too.
  const choices = groups.filter((g) => g.id !== account.id);

  const submit = (event: React.FormEvent) => {
    event.preventDefault();
    setError(null);
    setNotice(null);
    startTransition(async () => {
      const result = await modifyAccountAction({ id: account.id, name, alias, code, groupId: heading ? null : groupId });
      if (!result.ok) {
        setError(result.error ?? 'It could not be saved.');
        return;
      }
      setNotice(result.message ?? 'Saved.');
      router.refresh();
    });
  };

  return (
    <form onSubmit={submit} className="grid gap-4 sm:grid-cols-2" noValidate>
      <div className="sm:col-span-2">
        <Label htmlFor="ma-name" className="mb-1.5 block">Name<span className="ml-0.5 text-danger-600">*</span></Label>
        <Input id="ma-name" value={name} disabled={!canManage} onChange={(e) => setName(e.target.value)} />
      </div>
      <div>
        <Label htmlFor="ma-alias" className="mb-1.5 block">Alias</Label>
        <Input id="ma-alias" value={alias} disabled={!canManage} onChange={(e) => setAlias(e.target.value)} />
      </div>
      <div>
        <Label htmlFor="ma-code" className="mb-1.5 block">Code</Label>
        <Input id="ma-code" className="font-mono uppercase" value={code} maxLength={30}
          disabled={!canManage || account.isSystem} onChange={(e) => setCode(e.target.value)} />
        {account.isSystem && (
          <p className="mt-1 text-[11px] text-ink-500">A system ledger keeps its code — posting finds it by code. Its name and group can change.</p>
        )}
      </div>
      <div className="sm:col-span-2">
        <Label htmlFor="ma-group" className="mb-1.5 block">{account.isGroup ? 'Under group' : 'Group'}</Label>
        {heading ? (
          <p className="text-sm text-ink-600">A top heading — it stays at the top of the chart.</p>
        ) : (
          <GroupSelect id="ma-group" groups={choices} value={groupId} onChange={setGroupId}
            allowTypes={[account.type]} disabled={!canManage} />
        )}
        <p className="mt-1 text-[11px] text-ink-500">
          {account.type.toLowerCase()} — only groups of the same type are offered
          {hasPostings ? '; the type of a ledger with postings cannot change.' : '.'}
        </p>
      </div>
      <Feedback error={error} notice={notice} />
      {canManage && (
        <div className="sm:col-span-full">
          <Button type="submit" disabled={pending}>
            {pending ? <Loader2 className="animate-spin" aria-hidden /> : <Save aria-hidden />}
            Save changes
          </Button>
        </div>
      )}
    </form>
  );
}

/**
 * A ledger's opening balance. Saving posts only the difference from what is
 * already there — a posted journal is never edited (spec §23).
 */
export function OpeningBalanceForm({
  kind,
  id,
  current,
  refusal,
}: {
  readonly kind: 'ACCOUNT' | 'CUSTOMER' | 'SUPPLIER' | 'FINANCE_COMPANY';
  readonly id: string;
  /** Debit positive. */
  readonly current: number;
  /** Why this ledger takes its opening elsewhere, when it does. */
  readonly refusal?: React.ReactNode;
}) {
  const router = useRouter();
  const [amount, setAmount] = React.useState(current ? Math.abs(current).toFixed(2) : '');
  const [side, setSide] = React.useState<Side>(current < 0 ? 'CR' : 'DR');
  const [error, setError] = React.useState<string | null>(null);
  const [notice, setNotice] = React.useState<string | null>(null);
  const [pending, startTransition] = React.useTransition();

  if (refusal) return <p className="text-sm text-ink-600">{refusal}</p>;

  const submit = (event: React.FormEvent) => {
    event.preventDefault();
    setError(null);
    setNotice(null);
    if (!window.confirm('Post the change in opening balance against Opening Balance Equity?')) return;
    startTransition(async () => {
      const result = await setOpeningBalanceAction({ kind, id, amount: amount || '0', side });
      if (!result.ok) {
        setError(result.error ?? 'The opening balance could not be saved.');
        return;
      }
      setNotice(result.message ?? 'Saved.');
      router.refresh();
    });
  };

  return (
    <form onSubmit={submit} className={cn('grid gap-4 sm:grid-cols-2')} noValidate>
      <OpeningFields idPrefix="ob" amount={amount} side={side} onAmount={setAmount} onSide={setSide} />
      <Feedback error={error} notice={notice} />
      <div className="sm:col-span-full">
        <Button type="submit" disabled={pending} variant="secondary">
          {pending ? <Loader2 className="animate-spin" aria-hidden /> : <Save aria-hidden />}
          Save opening balance
        </Button>
      </div>
    </form>
  );
}
