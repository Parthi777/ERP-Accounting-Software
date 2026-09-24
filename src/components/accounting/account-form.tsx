'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { ChevronDown, Loader2, Plus } from 'lucide-react';

import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { Input, Label } from '@/components/ui/input';
import { createAccountAction, setAccountStatusAction } from '@/server/services/accounting/chart-actions';

type AccountType = 'ASSET' | 'LIABILITY' | 'EQUITY' | 'INCOME' | 'EXPENSE';

interface Heading {
  readonly id: string;
  readonly code: string;
  readonly name: string;
  readonly type: string;
}

const TYPES: { value: AccountType; label: string; hint: string }[] = [
  { value: 'ASSET', label: 'Asset', hint: 'What the business owns or is owed — a computer, a deposit.' },
  { value: 'LIABILITY', label: 'Liability', hint: 'What it owes — a loan, a payable.' },
  { value: 'EQUITY', label: 'Equity', hint: "The owner's stake — capital, drawings." },
  { value: 'INCOME', label: 'Income', hint: 'What it earns.' },
  { value: 'EXPENSE', label: 'Expense', hint: 'What it spends to earn it.' },
];

/**
 * Adding an account — spec §24.
 *
 * The normal side is not asked for: it follows from the type, and a form that
 * lets someone make an expense credit-normal is a form for making mistakes. The
 * heading list is filtered to the chosen type because the database refuses an
 * income account under the expenses heading anyway — better not to offer it.
 */
export function AccountForm({ headings }: { readonly headings: readonly Heading[] }) {
  const router = useRouter();
  const [open, setOpen] = React.useState(false);
  const [error, setError] = React.useState<string | null>(null);
  const [notice, setNotice] = React.useState<string | null>(null);
  const [pending, startTransition] = React.useTransition();

  const [type, setType] = React.useState<AccountType>('EXPENSE');
  const [code, setCode] = React.useState('');
  const [name, setName] = React.useState('');
  const [parentId, setParentId] = React.useState('');
  const [isGroup, setIsGroup] = React.useState(false);

  const parents = headings.filter((h) => h.type === type);

  const submit = (event: React.FormEvent) => {
    event.preventDefault();
    setError(null);
    setNotice(null);
    if (!code.trim()) return setError('Give the account a code.');
    if (name.trim().length < 2) return setError('Give the account a name.');

    startTransition(async () => {
      const result = await createAccountAction({
        code,
        name,
        type,
        parentId: parentId || null,
        isGroup,
      });
      if (!result.ok) {
        setError(result.error ?? 'The account could not be added.');
        return;
      }
      setNotice(result.message ?? 'Added.');
      setCode('');
      setName('');
      setIsGroup(false);
      router.refresh();
    });
  };

  if (!open) {
    return (
      <Button variant="secondary" size="sm" onClick={() => setOpen(true)}>
        <Plus aria-hidden />
        Add account
      </Button>
    );
  }

  return (
    <Panel className="p-5">
      <div className="mb-4 flex items-center justify-between">
        <h2 className="text-sm font-semibold text-ink-900">Add an account</h2>
        <Button variant="ghost" size="sm" onClick={() => setOpen(false)} aria-label="Close">
          <ChevronDown aria-hidden />
        </Button>
      </div>

      <form onSubmit={submit} className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4" noValidate>
        <div>
          <Label htmlFor="acc-type" className="mb-1.5 block">Type</Label>
          <select id="acc-type" value={type}
            onChange={(e) => { setType(e.target.value as AccountType); setParentId(''); }}
            className="h-9 w-full field px-3 text-sm">
            {TYPES.map((t) => <option key={t.value} value={t.value}>{t.label}</option>)}
          </select>
          <p className="mt-1 text-[11px] text-ink-400">{TYPES.find((t) => t.value === type)?.hint}</p>
        </div>

        <div>
          <Label htmlFor="acc-parent" className="mb-1.5 block">Under heading</Label>
          <select id="acc-parent" value={parentId} onChange={(e) => setParentId(e.target.value)}
            className="h-9 w-full field px-3 text-sm">
            <option value="">None (top level)</option>
            {parents.map((h) => <option key={h.id} value={h.id}>{h.code} — {h.name}</option>)}
          </select>
        </div>

        <div>
          <Label htmlFor="acc-code" className="mb-1.5 block">
            Code<span className="ml-0.5 text-danger-600">*</span>
          </Label>
          <Input id="acc-code" className="font-mono uppercase" value={code} maxLength={30}
            onChange={(e) => setCode(e.target.value)} placeholder="1952" />
        </div>

        <div>
          <Label htmlFor="acc-name" className="mb-1.5 block">
            Name<span className="ml-0.5 text-danger-600">*</span>
          </Label>
          <Input id="acc-name" value={name} onChange={(e) => setName(e.target.value)}
            placeholder="Office equipment" />
        </div>

        <label className="flex items-center gap-2 text-sm text-ink-700 sm:col-span-2 lg:col-span-4">
          <input type="checkbox" checked={isGroup} onChange={(e) => setIsGroup(e.target.checked)} />
          This is a heading — accounts sit beneath it, nothing is posted to it
        </label>

        {error && (
          <p role="alert" className="rounded-lg bg-danger-50 px-3 py-2 text-sm text-danger-700 sm:col-span-2 lg:col-span-4">
            {error}
          </p>
        )}
        {notice && (
          <p className="rounded-lg bg-positive-50 px-3 py-2 text-sm text-positive-700 sm:col-span-2 lg:col-span-4">
            {notice}
          </p>
        )}

        <div className="sm:col-span-2 lg:col-span-4">
          <Button type="submit" disabled={pending}>
            {pending && <Loader2 className="animate-spin" aria-hidden />}
            Add account
          </Button>
        </div>
      </form>
    </Panel>
  );
}

/**
 * Deactivate / reactivate. The database refuses to deactivate an account that
 * still carries a balance — its money would leave every report — and says what
 * the balance is, which is shown here rather than a generic failure.
 */
export function AccountStatusToggle({
  accountId,
  status,
}: {
  readonly accountId: string;
  readonly status: string;
}) {
  const router = useRouter();
  const [pending, startTransition] = React.useTransition();
  const [error, setError] = React.useState<string | null>(null);
  const next = status === 'ACTIVE' ? 'INACTIVE' : 'ACTIVE';

  return (
    <span className="inline-flex flex-col items-end">
      <Button
        variant="ghost"
        size="sm"
        disabled={pending}
        onClick={() =>
          startTransition(async () => {
            setError(null);
            const result = await setAccountStatusAction(accountId, next);
            if (!result.ok) {
              setError(result.error ?? 'Could not change the status.');
              return;
            }
            router.refresh();
          })
        }
      >
        {pending && <Loader2 className="animate-spin" aria-hidden />}
        {next === 'INACTIVE' ? 'Deactivate' : 'Reactivate'}
      </Button>
      {error && <span role="alert" className="max-w-64 text-right text-[11px] text-danger-700">{error}</span>}
    </span>
  );
}
