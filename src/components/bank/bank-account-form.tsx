'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Loader2 } from 'lucide-react';

import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { Input, Label } from '@/components/ui/input';
import { createBankAccountAction, updateBankAccountAction } from '@/server/services/bank/bank-actions';

interface BranchOption {
  readonly id: string;
  readonly name: string;
}

export interface BankAccountDefaults {
  readonly id: string;
  readonly name: string;
  readonly bankName: string;
  readonly accountNumber: string;
  readonly ifsc: string | null;
  readonly accountType: string;
  readonly status: string;
  readonly branchId: string | null;
  readonly openingBalance: string;
}

const ACCOUNT_TYPES = [
  { value: 'CURRENT', label: 'Current' },
  { value: 'SAVINGS', label: 'Savings' },
  { value: 'OD', label: 'Overdraft' },
  { value: 'CC', label: 'Cash credit' },
];

/**
 * Add or edit a bank account — spec §38.
 *
 * The opening balance appears only when creating. It is not a number stored
 * beside the account: create_bank_account (0073) posts it against 3300 Opening
 * Balance Equity, so the bank book and the trial balance agree from day one.
 * Once posted it is a journal, and a posted journal is corrected by reversal
 * rather than by editing the field that produced it (spec §23) — which is why
 * the edit form has no such field.
 */
export function BankAccountForm({
  branches,
  account,
}: {
  readonly branches: readonly BranchOption[];
  readonly account?: BankAccountDefaults;
}) {
  const router = useRouter();
  const editing = account !== undefined;

  const [error, setError] = React.useState<string | null>(null);
  const [pending, startTransition] = React.useTransition();

  const [name, setName] = React.useState(account?.name ?? '');
  const [bankName, setBankName] = React.useState(account?.bankName ?? '');
  const [accountNumber, setAccountNumber] = React.useState(account?.accountNumber ?? '');
  const [ifsc, setIfsc] = React.useState(account?.ifsc ?? '');
  const [accountType, setAccountType] = React.useState(account?.accountType ?? 'CURRENT');
  const [status, setStatus] = React.useState(account?.status ?? 'ACTIVE');
  const [branchId, setBranchId] = React.useState(account?.branchId ?? '');
  const [openingBalance, setOpeningBalance] = React.useState('');
  const [asOn, setAsOn] = React.useState(() => new Date().toISOString().slice(0, 10));

  const submit = (event: React.FormEvent) => {
    event.preventDefault();
    setError(null);

    if (!name.trim()) return setError('Give the account a name you will recognise on a receipt.');
    if (!bankName.trim()) return setError('Name the bank.');
    if (!editing && !accountNumber.trim()) return setError('Enter the account number.');

    // The database enforces this too; catching it here saves a round trip and
    // says which field, which the constraint violation cannot.
    const ifscValue = ifsc.trim().toUpperCase();
    if (ifscValue && !/^[A-Z]{4}0[A-Z0-9]{6}$/.test(ifscValue)) {
      return setError('An IFSC is four letters, a zero, then six more characters — HDFC0001234.');
    }

    startTransition(async () => {
      const result = editing
        ? await updateBankAccountAction(account.id, {
            name: name.trim(),
            bankName: bankName.trim(),
            ifsc: ifscValue,
            accountType,
            status,
          })
        : await createBankAccountAction({
            name: name.trim(),
            bankName: bankName.trim(),
            accountNumber: accountNumber.trim(),
            ifsc: ifscValue || null,
            accountType,
            branchId: branchId || null,
            openingBalance: Number(openingBalance) || 0,
            asOn,
          });

      if (!result.ok) {
        setError(result.error ?? 'Could not save the account.');
        return;
      }
      router.push('/bank');
      router.refresh();
    });
  };

  return (
    <Panel className="p-5">
      <form onSubmit={submit} className="grid gap-4 sm:grid-cols-2" noValidate>
        <div>
          <Label htmlFor="ba-name" className="mb-1.5 block">
            Account name<span className="ml-0.5 text-danger-600">*</span>
          </Label>
          <Input id="ba-name" value={name} onChange={(e) => setName(e.target.value)}
            placeholder="HDFC Current" />
        </div>

        <div>
          <Label htmlFor="ba-bank" className="mb-1.5 block">
            Bank<span className="ml-0.5 text-danger-600">*</span>
          </Label>
          <Input id="ba-bank" value={bankName} onChange={(e) => setBankName(e.target.value)}
            placeholder="HDFC Bank" />
        </div>

        <div>
          <Label htmlFor="ba-number" className="mb-1.5 block">
            Account number{!editing && <span className="ml-0.5 text-danger-600">*</span>}
          </Label>
          <Input id="ba-number" className="font-mono" value={accountNumber} disabled={editing}
            onChange={(e) => setAccountNumber(e.target.value)} placeholder="50200012345678" />
          {editing && (
            <p className="mt-1 text-[11px] text-ink-400">
              The number cannot change — entries and statement lines are matched against it.
            </p>
          )}
        </div>

        <div>
          <Label htmlFor="ba-ifsc" className="mb-1.5 block">IFSC</Label>
          <Input id="ba-ifsc" className="font-mono uppercase" value={ifsc} maxLength={11}
            onChange={(e) => setIfsc(e.target.value)} placeholder="HDFC0001234" />
        </div>

        <div>
          <Label htmlFor="ba-type" className="mb-1.5 block">Account type</Label>
          <select id="ba-type" value={accountType} onChange={(e) => setAccountType(e.target.value)}
            className="h-9 w-full field px-3 text-sm">
            {ACCOUNT_TYPES.map((t) => <option key={t.value} value={t.value}>{t.label}</option>)}
          </select>
        </div>

        {editing ? (
          <div>
            <Label htmlFor="ba-status" className="mb-1.5 block">Status</Label>
            <select id="ba-status" value={status} onChange={(e) => setStatus(e.target.value)}
              className="h-9 w-full field px-3 text-sm">
              <option value="ACTIVE">Active</option>
              <option value="INACTIVE">Inactive</option>
              <option value="CLOSED">Closed</option>
            </select>
          </div>
        ) : (
          <div>
            <Label htmlFor="ba-branch" className="mb-1.5 block">Branch</Label>
            <select id="ba-branch" value={branchId} onChange={(e) => setBranchId(e.target.value)}
              className="h-9 w-full field px-3 text-sm">
              <option value="">Dealer-wide</option>
              {branches.map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}
            </select>
            <p className="mt-1 text-[11px] text-ink-400">
              A collection account shared across branches stays dealer-wide.
            </p>
          </div>
        )}

        {!editing && (
          <>
            <div className="sm:col-span-2 mt-2 border-t border-ink-100 pt-4">
              <h3 className="text-sm font-medium text-ink-900">Opening balance</h3>
              <p className="mt-1 text-xs text-ink-500">
                What the bank held when the books started here. This posts a journal against
                3300&nbsp;Opening Balance Equity, so the bank book and the trial balance agree
                from the first day. Leave it at zero if the account starts empty — nothing is
                posted then. Overdrawn? Enter a negative figure.
              </p>
            </div>

            <div>
              <Label htmlFor="ba-opening" className="mb-1.5 block">Balance</Label>
              <div className="relative">
                <span className="pointer-events-none absolute left-3 top-1/2 -translate-y-1/2 text-sm text-ink-400">₹</span>
                <Input id="ba-opening" type="number" step="0.01" className="pl-7 numeric"
                  value={openingBalance} onChange={(e) => setOpeningBalance(e.target.value)}
                  placeholder="0.00" />
              </div>
            </div>

            <div>
              <Label htmlFor="ba-ason" className="mb-1.5 block">As at</Label>
              <Input id="ba-ason" type="date" value={asOn} onChange={(e) => setAsOn(e.target.value)} />
              <p className="mt-1 text-[11px] text-ink-400">
                Usually the day before trading started here.
              </p>
            </div>
          </>
        )}

        {error && (
          <p role="alert" className="sm:col-span-2 rounded-lg bg-danger-50 px-3 py-2 text-sm text-danger-700">
            {error}
          </p>
        )}

        <div className="sm:col-span-2 flex gap-2">
          <Button type="submit" disabled={pending}>
            {pending && <Loader2 className="animate-spin" aria-hidden />}
            {editing ? 'Save changes' : 'Add bank account'}
          </Button>
          <Button type="button" variant="secondary" onClick={() => router.push('/bank')} disabled={pending}>
            Cancel
          </Button>
        </div>
      </form>
    </Panel>
  );
}
