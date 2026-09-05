'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Loader2, Pencil, Plus, Power } from 'lucide-react';

import { saveBranchAction, setBranchStatusAction } from '@/server/services/org/admin-actions';
import { SolidPanel, Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Input, Label } from '@/components/ui/input';

/**
 * The dealer's branches — spec §5, §36.
 *
 * A branch is not a label: every sale, receipt and journal is scoped to one, and
 * a new branch gets a cash account the moment it is created, because without one
 * the first counter receipt fails with "This branch has no cash account".
 *
 * Branches are suspended rather than deleted. Their transactions are part of the
 * dealer's ledger and outlive the branch itself.
 */
export interface BranchSummary {
  readonly id: string;
  readonly code: string;
  readonly name: string;
  readonly city: string | null;
  readonly state: string | null;
  readonly gstin: string | null;
  readonly is_head_office: boolean;
  readonly status: string;
}

export function BranchManager({
  branches,
  canManage,
}: {
  readonly branches: readonly BranchSummary[];
  readonly canManage: boolean;
}) {
  const router = useRouter();
  const [editing, setEditing] = React.useState<BranchSummary | 'new' | null>(null);
  const [notice, setNotice] = React.useState<string | null>(null);
  const [error, setError] = React.useState<string | null>(null);
  const [pending, startTransition] = React.useTransition();

  const toggleStatus = (branch: BranchSummary) => {
    setNotice(null);
    setError(null);
    startTransition(async () => {
      const next = branch.status === 'ACTIVE' ? 'SUSPENDED' : 'ACTIVE';
      const result = await setBranchStatusAction(branch.id, next);
      if (result.ok) setNotice(result.message ?? 'Updated.');
      else setError(result.error ?? 'That could not be changed.');
      router.refresh();
    });
  };

  return (
    <div className="space-y-4">
      {notice && (
        <div role="status" className="rounded-lg border border-positive-200 bg-positive-50 px-3 py-2 text-sm text-positive-700">
          {notice}
        </div>
      )}
      {error && (
        <div role="alert" className="rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
          {error}
        </div>
      )}

      {canManage && (
        <div className="flex justify-end">
          <Button onClick={() => setEditing('new')}>
            <Plus aria-hidden />
            New branch
          </Button>
        </div>
      )}

      <SolidPanel className="overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full border-collapse text-sm">
            <caption className="sr-only">Branches</caption>
            <thead>
              <tr className="bg-ink-50">
                <th scope="col" className="px-4 py-2.5 text-left text-[11px] font-semibold uppercase tracking-wide text-ink-500">Branch</th>
                <th scope="col" className="px-4 py-2.5 text-left text-[11px] font-semibold uppercase tracking-wide text-ink-500">Location</th>
                <th scope="col" className="px-4 py-2.5 text-left text-[11px] font-semibold uppercase tracking-wide text-ink-500">GSTIN</th>
                <th scope="col" className="px-4 py-2.5 text-left text-[11px] font-semibold uppercase tracking-wide text-ink-500">Status</th>
                {canManage && <th scope="col" className="px-4 py-2.5" />}
              </tr>
            </thead>
            <tbody>
              {branches.map((branch) => (
                <tr key={branch.id} className="border-t border-ink-100">
                  <td className="px-4 py-2">
                    <span className="flex flex-wrap items-center gap-2">
                      <span className="font-medium text-ink-800">{branch.name}</span>
                      {branch.is_head_office && <Badge variant="info">Head office</Badge>}
                    </span>
                    <span className="block font-mono text-[11px] text-ink-400">{branch.code}</span>
                  </td>
                  <td className="px-4 py-2 text-xs text-ink-600">
                    {[branch.city, branch.state].filter(Boolean).join(', ') || <span className="text-ink-300">—</span>}
                  </td>
                  <td className="px-4 py-2 font-mono text-xs text-ink-600">
                    {branch.gstin ?? <span className="text-ink-300">—</span>}
                  </td>
                  <td className="px-4 py-2">
                    <Badge variant={branch.status === 'ACTIVE' ? 'positive' : 'warning'}>{branch.status}</Badge>
                  </td>
                  {canManage && (
                    <td className="px-4 py-2">
                      <span className="flex justify-end gap-1">
                        <Button variant="ghost" size="sm" onClick={() => setEditing(branch)} title="Edit">
                          <Pencil aria-hidden />
                        </Button>
                        <Button variant="ghost" size="sm" disabled={pending}
                          onClick={() => toggleStatus(branch)}
                          title={branch.status === 'ACTIVE' ? 'Suspend' : 'Reactivate'}>
                          <Power aria-hidden className={branch.status === 'ACTIVE' ? 'text-warning-600' : 'text-positive-600'} />
                        </Button>
                      </span>
                    </td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </SolidPanel>

      <Panel className="p-4">
        <p className="text-xs text-ink-600">
          A branch is suspended, never deleted — its sales, receipts and journals are part of the
          dealer&rsquo;s ledger and outlive it. A suspended branch takes no new work; everything
          already booked to it stays exactly as it is.
        </p>
      </Panel>

      {editing && (
        <BranchDialog
          key={editing === 'new' ? 'new' : editing.id}
          branch={editing === 'new' ? null : editing}
          onCancel={() => setEditing(null)}
          onDone={(message, ok) => {
            setEditing(null);
            if (ok) { setNotice(message); setError(null); } else { setError(message); }
            router.refresh();
          }}
        />
      )}
    </div>
  );
}

function BranchDialog({
  branch,
  onCancel,
  onDone,
}: {
  readonly branch: BranchSummary | null;
  readonly onCancel: () => void;
  readonly onDone: (message: string, ok: boolean) => void;
}) {
  const [pending, startTransition] = React.useTransition();
  const [error, setError] = React.useState<string | null>(null);
  const [form, setForm] = React.useState({
    code: branch?.code ?? '',
    name: branch?.name ?? '',
    city: branch?.city ?? '',
    state: branch?.state ?? '',
    stateCode: '',
    gstin: branch?.gstin ?? '',
    phone: '',
    isHeadOffice: branch?.is_head_office ?? false,
  });

  const set = (key: keyof typeof form) => (e: React.ChangeEvent<HTMLInputElement>) =>
    setForm((f) => ({ ...f, [key]: e.target.value }));

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-ink-900/25 p-4 backdrop-blur-sm"
      role="dialog" aria-modal="true" onClick={onCancel}>
      <div className="glass-strong w-full max-w-lg overflow-y-auto rounded-2xl p-6" onClick={(e) => e.stopPropagation()}>
        <h2 className="text-sm font-semibold text-ink-900">
          {branch ? `Edit ${branch.name}` : 'New branch'}
        </h2>
        {!branch && (
          <p className="mt-1 text-sm text-ink-600">
            Its cash account is created at the same time, so the counter can take money on day one.
          </p>
        )}

        {error && (
          <div role="alert" className="mt-3 rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
            {error}
          </div>
        )}

        <div className="mt-4 grid gap-3 sm:grid-cols-2">
          <div>
            <Label htmlFor="b-code" className="mb-1.5 block">Code<span className="ml-0.5 text-danger-600">*</span></Label>
            <Input id="b-code" value={form.code} disabled={branch !== null}
              onChange={set('code')} placeholder="NORTH" />
          </div>
          <div>
            <Label htmlFor="b-name" className="mb-1.5 block">Name<span className="ml-0.5 text-danger-600">*</span></Label>
            <Input id="b-name" value={form.name} onChange={set('name')} placeholder="North Showroom" />
          </div>
          <div>
            <Label htmlFor="b-city" className="mb-1.5 block">City</Label>
            <Input id="b-city" value={form.city} onChange={set('city')} />
          </div>
          <div>
            <Label htmlFor="b-state" className="mb-1.5 block">State</Label>
            <Input id="b-state" value={form.state} onChange={set('state')} />
          </div>
          <div>
            <Label htmlFor="b-statecode" className="mb-1.5 block">GST state code</Label>
            <Input id="b-statecode" value={form.stateCode} onChange={set('stateCode')} placeholder="33" />
          </div>
          <div>
            <Label htmlFor="b-phone" className="mb-1.5 block">Phone</Label>
            <Input id="b-phone" value={form.phone} onChange={set('phone')} />
          </div>
          <div className="sm:col-span-2">
            <Label htmlFor="b-gstin" className="mb-1.5 block">GSTIN</Label>
            <Input id="b-gstin" value={form.gstin} onChange={set('gstin')} placeholder="33AABCS1234A1Z5" />
            <p className="mt-1 text-xs text-ink-400">
              A branch in another state files under its own GSTIN.
            </p>
          </div>
        </div>

        <label className="mt-3 flex items-center gap-2 text-sm text-ink-700">
          <input type="checkbox" checked={form.isHeadOffice}
            onChange={(e) => setForm((f) => ({ ...f, isHeadOffice: e.target.checked }))} />
          This is the head office
        </label>

        <div className="mt-5 flex justify-end gap-2">
          <Button variant="secondary" size="sm" onClick={onCancel} disabled={pending}>Cancel</Button>
          <Button size="sm" disabled={pending || !form.code.trim() || !form.name.trim()}
            onClick={() => startTransition(async () => {
              setError(null);
              const result = await saveBranchAction({ id: branch?.id ?? null, ...form });
              if (!result.ok) { setError(result.error ?? 'That could not be saved.'); return; }
              onDone(result.message ?? 'Saved.', true);
            })}>
            {pending && <Loader2 className="animate-spin" aria-hidden />}
            {branch ? 'Save changes' : 'Add branch'}
          </Button>
        </div>
      </div>
    </div>
  );
}
