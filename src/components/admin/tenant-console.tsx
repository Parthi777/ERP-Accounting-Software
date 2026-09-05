'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Building2, Check, Loader2, Mail, Pencil, Plus, Trash2, TriangleAlert, X } from 'lucide-react';

import type { TenantRow, ReadinessCheck } from '@/server/services/org/provisioning-service';
import {
  provisionDealerAction,
  purgeDealerAction,
  resendOwnerInviteAction,
} from '@/server/services/org/provisioning-actions';
import {
  getDealerBranchesAction,
  saveBranchAction,
  setBranchStatusAction,
} from '@/server/services/org/admin-actions';
import { Panel, SolidPanel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { Input, Label } from '@/components/ui/input';
import { formatDate } from '@/lib/format';

/**
 * The tenant console — spec §4, §6, §48.
 *
 * Onboarding used to mean editing seed.sql and running it against production.
 * This is that, as six fields: the form collects only what cannot be defaulted,
 * and everything else — chart of accounts, accounting rules, document sequences,
 * cash account, accounting period — is provisioned from code.
 *
 * The result panel shows the readiness report rather than a success toast,
 * because "created" and "can raise an invoice" are different claims and only the
 * second one matters.
 */
export function TenantConsole({ tenants }: { readonly tenants: readonly TenantRow[] }) {
  const router = useRouter();
  const [creating, setCreating] = React.useState(false);
  const [purging, setPurging] = React.useState<TenantRow | null>(null);
  const [branchesFor, setBranchesFor] = React.useState<TenantRow | null>(null);
  const [notice, setNotice] = React.useState<string | null>(null);
  const [warning, setWarning] = React.useState<string | null>(null);
  const [readiness, setReadiness] = React.useState<readonly ReadinessCheck[] | null>(null);
  const [pending, startTransition] = React.useTransition();

  const resend = (tenant: TenantRow) => {
    setNotice(null);
    setWarning(null);
    startTransition(async () => {
      const result = await resendOwnerInviteAction(tenant.id);
      if (result.ok) setNotice(result.message ?? 'Invite sent.');
      else setWarning(result.error ?? 'The invite could not be sent.');
    });
  };

  return (
    <div className="space-y-4">
      {notice && (
        <div role="status" className="rounded-lg border border-positive-200 bg-positive-50 px-3 py-2 text-sm text-positive-700">
          {notice}
        </div>
      )}
      {warning && (
        <div role="alert" className="rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
          {warning}
        </div>
      )}

      {readiness && (
        <Panel className="p-4">
          <div className="mb-2 flex items-center justify-between gap-3">
            <h2 className="text-sm font-semibold text-ink-900">Readiness</h2>
            <Button variant="ghost" size="sm" onClick={() => setReadiness(null)} aria-label="Dismiss">
              <X aria-hidden />
            </Button>
          </div>
          <ul className="grid gap-1.5 sm:grid-cols-2">
            {readiness.map((check) => (
              <li key={check.name} className="flex items-start gap-2 text-sm">
                {check.ok
                  ? <Check className="mt-0.5 size-4 shrink-0 text-positive-600" aria-hidden />
                  : <TriangleAlert className="mt-0.5 size-4 shrink-0 text-danger-600" aria-hidden />}
                <span>
                  <span className={check.ok ? 'text-ink-700' : 'font-medium text-danger-700'}>
                    {check.name}
                  </span>
                  <span className="block text-[11px] text-ink-400">{check.detail}</span>
                </span>
              </li>
            ))}
          </ul>
        </Panel>
      )}

      <div className="flex justify-end">
        <Button onClick={() => setCreating(true)}>
          <Plus aria-hidden />
          New tenant
        </Button>
      </div>

      <SolidPanel className="overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full border-collapse text-sm">
            <caption className="sr-only">Tenants</caption>
            <thead>
              <tr className="bg-ink-50">
                <th scope="col" className="px-4 py-2.5 text-left text-[11px] font-semibold uppercase tracking-wide text-ink-500">Dealer</th>
                <th scope="col" className="px-4 py-2.5 text-left text-[11px] font-semibold uppercase tracking-wide text-ink-500">GSTIN</th>
                <th scope="col" className="px-4 py-2.5 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">Branches</th>
                <th scope="col" className="px-4 py-2.5 text-right text-[11px] font-semibold uppercase tracking-wide text-ink-500">Users</th>
                <th scope="col" className="px-4 py-2.5 text-left text-[11px] font-semibold uppercase tracking-wide text-ink-500">Onboarded</th>
                <th scope="col" className="px-4 py-2.5 text-left text-[11px] font-semibold uppercase tracking-wide text-ink-500">Status</th>
                <th scope="col" className="px-4 py-2.5" />
              </tr>
            </thead>
            <tbody>
              {tenants.length === 0 ? (
                <tr>
                  <td colSpan={7} className="px-4 py-12 text-center text-sm text-ink-400">
                    No tenants yet. Create the first one.
                  </td>
                </tr>
              ) : (
                tenants.map((t) => (
                  <tr key={t.id} className="border-t border-ink-100">
                    <td className="px-4 py-2">
                      <span className="block font-medium text-ink-800">{t.tradeName ?? t.legalName}</span>
                      <span className="block font-mono text-[11px] text-ink-400">
                        {t.code}{t.city ? ` · ${t.city}` : ''}{t.state ? `, ${t.state}` : ''}
                      </span>
                    </td>
                    <td className="px-4 py-2 font-mono text-xs text-ink-600">
                      {t.gstin ?? <span className="text-ink-300">—</span>}
                    </td>
                    <td className="numeric px-4 py-2 text-right">{t.branchCount}</td>
                    <td className="numeric px-4 py-2 text-right">{t.userCount}</td>
                    <td className="px-4 py-2 text-xs text-ink-500">{formatDate(t.createdAt)}</td>
                    <td className="px-4 py-2">
                      <Badge
                        variant={
                          t.status === 'ACTIVE' ? 'positive'
                          : t.status === 'SUSPENDED' ? 'warning'
                          : 'neutral'
                        }
                      >
                        {t.status}
                      </Badge>
                    </td>
                    <td className="px-4 py-2">
                      <span className="flex justify-end gap-1">
                        <Button variant="ghost" size="sm"
                          onClick={() => setBranchesFor(t)} title="Branches">
                          <Building2 aria-hidden />
                        </Button>
                        <Button variant="ghost" size="sm" disabled={pending}
                          onClick={() => resend(t)} title="Resend the owner's invite">
                          <Mail aria-hidden />
                        </Button>
                        {/* Only offered while it is honest: once anything is
                            posted the database refuses, so the button goes. */}
                        {!t.hasPosted && (
                          <Button variant="ghost" size="sm" disabled={pending}
                            onClick={() => setPurging(t)} title="Delete this tenant">
                            <Trash2 aria-hidden className="text-danger-600" />
                          </Button>
                        )}
                      </span>
                    </td>
                  </tr>
                ))
              )}
            </tbody>
          </table>
        </div>
      </SolidPanel>

      {tenants.some((t) => t.hasPosted) && (
        <p className="text-[11px] text-ink-400">
          A tenant that has posted to a ledger cannot be deleted — that ledger is their statutory
          record. Set them to CLOSED instead, which ends access everywhere at once.
        </p>
      )}

      {creating && (
        <NewTenantDialog
          onCancel={() => setCreating(false)}
          onDone={(message, checks, failed) => {
            setCreating(false);
            setReadiness(checks);
            if (failed) setWarning(message);
            else setNotice(message);
            router.refresh();
          }}
        />
      )}

      {branchesFor && (
        <BranchesDialog
          key={branchesFor.id}
          tenant={branchesFor}
          onClose={() => { setBranchesFor(null); router.refresh(); }}
        />
      )}

      {purging && (
        <PurgeDialog
          tenant={purging}
          onCancel={() => setPurging(null)}
          onDone={(message, ok) => {
            setPurging(null);
            if (ok) setNotice(message); else setWarning(message);
            router.refresh();
          }}
        />
      )}
    </div>
  );
}

function NewTenantDialog({
  onCancel,
  onDone,
}: {
  readonly onCancel: () => void;
  readonly onDone: (message: string, checks: readonly ReadinessCheck[] | null, failed: boolean) => void;
}) {
  const [pending, startTransition] = React.useTransition();
  const [error, setError] = React.useState<string | null>(null);
  const [form, setForm] = React.useState({
    code: '', legalName: '', tradeName: '', state: 'Tamil Nadu', stateCode: '33',
    city: '', phone: '', gstin: '', pan: '', branchName: 'Head Office',
    ownerName: '', ownerEmail: '',
  });

  const set = (key: keyof typeof form) => (e: React.ChangeEvent<HTMLInputElement>) =>
    setForm((f) => ({ ...f, [key]: e.target.value }));

  const submit = () => {
    setError(null);
    if (!form.code.trim()) return setError('A dealer code is required.');
    if (!form.legalName.trim()) return setError('The legal name is required.');
    if (!/^\d{2}$/.test(form.stateCode.trim())) {
      return setError('The state code is two digits — it decides CGST+SGST versus IGST.');
    }
    if (!form.ownerName.trim() || !form.ownerEmail.trim()) {
      return setError("The owner's name and email are required — they get the first login.");
    }

    startTransition(async () => {
      const result = await provisionDealerAction(form);
      if (!result.ok) {
        setError(result.error ?? 'The tenant could not be created.');
        return;
      }
      onDone(result.message ?? 'Tenant created.', result.readiness ?? null, Boolean(result.inviteFailed));
    });
  };

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-ink-900/25 p-4 backdrop-blur-sm"
      role="dialog" aria-modal="true" onClick={onCancel}>
      <div className="glass-strong max-h-[90vh] w-full max-w-2xl overflow-y-auto rounded-2xl p-6"
        onClick={(e) => e.stopPropagation()}>
        <h2 className="text-sm font-semibold text-ink-900">Onboard a dealer</h2>
        <p className="mt-1 text-sm text-ink-600">
          The chart of accounts, accounting rules, document sequences, cash account and accounting
          period are all created from defaults. If anything fails, nothing is written.
        </p>

        {error && (
          <div role="alert" className="mt-3 rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
            {error}
          </div>
        )}

        <h3 className="mt-4 text-[11px] font-semibold uppercase tracking-wide text-ink-500">The dealership</h3>
        <div className="mt-2 grid gap-3 sm:grid-cols-2">
          <Field id="code" label="Dealer code" required value={form.code} onChange={set('code')}
            placeholder="SBM" hint="Short, unique across the platform." />
          <Field id="legalName" label="Legal name" required value={form.legalName}
            onChange={set('legalName')} placeholder="Sri Balaji Motors Private Limited" />
          <Field id="tradeName" label="Trade name" value={form.tradeName}
            onChange={set('tradeName')} placeholder="Sri Balaji Motors" hint="Defaults to the legal name." />
          <Field id="branchName" label="First branch" value={form.branchName}
            onChange={set('branchName')} placeholder="Head Office" />
          <Field id="city" label="City" value={form.city} onChange={set('city')} placeholder="Chennai" />
          <Field id="state" label="State" value={form.state} onChange={set('state')} />
          <Field id="stateCode" label="GST state code" required value={form.stateCode}
            onChange={set('stateCode')} placeholder="33"
            hint="Two digits. Decides CGST+SGST versus IGST on every invoice." />
          <Field id="phone" label="Phone" value={form.phone} onChange={set('phone')} />
          <Field id="gstin" label="GSTIN" value={form.gstin} onChange={set('gstin')}
            placeholder="33AABCS1234A1Z5" hint="Unique across tenants." />
          <Field id="pan" label="PAN" value={form.pan} onChange={set('pan')} placeholder="AABCS1234A" />
        </div>

        <h3 className="mt-5 text-[11px] font-semibold uppercase tracking-wide text-ink-500">The owner</h3>
        <div className="mt-2 grid gap-3 sm:grid-cols-2">
          <Field id="ownerName" label="Name" required value={form.ownerName} onChange={set('ownerName')} />
          <Field id="ownerEmail" label="Email" required type="email" value={form.ownerEmail}
            onChange={set('ownerEmail')}
            hint="They get an invite and set their own password. You never see it." />
        </div>

        <div className="mt-5 flex flex-wrap justify-end gap-2">
          <Button variant="secondary" size="sm" onClick={onCancel} disabled={pending}>Cancel</Button>
          <Button size="sm" onClick={submit} disabled={pending}>
            {pending && <Loader2 className="animate-spin" aria-hidden />}
            {pending ? 'Provisioning…' : 'Create tenant'}
          </Button>
        </div>
      </div>
    </div>
  );
}

function PurgeDialog({
  tenant,
  onCancel,
  onDone,
}: {
  readonly tenant: TenantRow;
  readonly onCancel: () => void;
  readonly onDone: (message: string, ok: boolean) => void;
}) {
  const [pending, startTransition] = React.useTransition();
  const [reason, setReason] = React.useState('');
  const [confirm, setConfirm] = React.useState('');

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-ink-900/25 p-4 backdrop-blur-sm"
      role="dialog" aria-modal="true" onClick={onCancel}>
      <div className="glass-strong w-full max-w-md rounded-2xl p-6" onClick={(e) => e.stopPropagation()}>
        <h2 className="text-sm font-semibold text-ink-900">Delete {tenant.tradeName ?? tenant.legalName}?</h2>
        <p className="mt-1 text-sm text-ink-600">
          This tenant has posted nothing, so it can still be removed cleanly — its accounts,
          branches, users and logins all go. If it had posted to a ledger the database would
          refuse, and closing it would be the only option.
        </p>

        <label className="mt-4 block">
          <span className="text-sm font-medium text-ink-700">
            Reason<span className="ml-0.5 text-danger-600">*</span>
          </span>
          <textarea rows={2} value={reason} onChange={(e) => setReason(e.target.value)}
            placeholder="e.g. Wrong GSTIN, re-onboarding"
            className="mt-1 w-full rounded-lg border border-ink-200 bg-white px-3 py-2 text-sm shadow-sm" />
          <span className="mt-1 block text-xs text-ink-400">Written to the audit trail before the rows go.</span>
        </label>

        <label className="mt-3 block">
          <span className="text-sm font-medium text-ink-700">
            Type <span className="font-mono">{tenant.code}</span> to confirm
          </span>
          <Input className="mt-1" value={confirm} onChange={(e) => setConfirm(e.target.value)} />
        </label>

        <div className="mt-4 flex justify-end gap-2">
          <Button variant="secondary" size="sm" onClick={onCancel} disabled={pending}>Cancel</Button>
          <Button variant="danger" size="sm"
            disabled={pending || !reason.trim() || confirm.trim().toUpperCase() !== tenant.code}
            onClick={() => startTransition(async () => {
              const result = await purgeDealerAction(tenant.id, reason);
              onDone(result.message ?? result.error ?? 'Done.', result.ok);
            })}>
            {pending && <Loader2 className="animate-spin" aria-hidden />}
            Delete tenant
          </Button>
        </div>
      </div>
    </div>
  );
}

function Field({
  id, label, value, onChange, required = false, placeholder, hint, type = 'text',
}: {
  readonly id: string;
  readonly label: string;
  readonly value: string;
  readonly onChange: (e: React.ChangeEvent<HTMLInputElement>) => void;
  readonly required?: boolean;
  readonly placeholder?: string;
  readonly hint?: string;
  readonly type?: string;
}) {
  return (
    <div>
      <Label htmlFor={id} className="mb-1.5 block">
        {label}{required && <span className="ml-0.5 text-danger-600">*</span>}
      </Label>
      <Input id={id} type={type} value={value} onChange={onChange} placeholder={placeholder} />
      {hint && <p className="mt-1 text-xs text-ink-400">{hint}</p>}
    </div>
  );
}

/**
 * One tenant's branches, managed from the console.
 *
 * Here rather than only on the dealer's own Administration screen, because a
 * dealership arriving with three showrooms needs all three before its staff can
 * be given branch access — and at that point the dealer has nobody logged in to
 * add them.
 */
function BranchesDialog({
  tenant,
  onClose,
}: {
  readonly tenant: TenantRow;
  readonly onClose: () => void;
}) {
  const [branches, setBranches] = React.useState<
    readonly {
      id: string; code: string; name: string; city: string | null;
      state: string | null; gstin: string | null; is_head_office: boolean;
      status: string; hasActivity: boolean;
    }[]
  >([]);
  const [loading, setLoading] = React.useState(true);
  const [adding, setAdding] = React.useState(false);
  const [editing, setEditing] = React.useState<string | null>(null);
  const [pending, startTransition] = React.useTransition();
  const [error, setError] = React.useState<string | null>(null);
  const [form, setForm] = React.useState({
    code: '', name: '', city: tenant.city ?? '', state: tenant.state ?? '',
    stateCode: '', gstin: '', phone: '', isHeadOffice: false,
  });

  const load = React.useCallback(() => {
    void getDealerBranchesAction(tenant.id).then((rows) => {
      setBranches(rows);
      setLoading(false);
    });
  }, [tenant.id]);

  React.useEffect(load, [load]);

  const reset = () => {
    setForm({
      code: '', name: '', city: tenant.city ?? '', state: tenant.state ?? '',
      stateCode: '', gstin: '', phone: '', isHeadOffice: false,
    });
    setAdding(false);
    setEditing(null);
  };

  const save = () => {
    setError(null);
    if (!form.code.trim() || !form.name.trim()) {
      return setError('A branch needs a code and a name.');
    }
    startTransition(async () => {
      const result = await saveBranchAction({ id: editing, dealerId: tenant.id, ...form });
      if (!result.ok) {
        setError(result.error ?? 'That could not be saved.');
        return;
      }
      reset();
      load();
    });
  };

  const toggle = (id: string, status: string) => {
    setError(null);
    startTransition(async () => {
      const result = await setBranchStatusAction(id, status === 'ACTIVE' ? 'SUSPENDED' : 'ACTIVE');
      if (!result.ok) setError(result.error ?? 'That could not be changed.');
      load();
    });
  };

  const set = (key: keyof typeof form) => (e: React.ChangeEvent<HTMLInputElement>) =>
    setForm((f) => ({ ...f, [key]: e.target.value }));

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-ink-900/25 p-4 backdrop-blur-sm"
      role="dialog" aria-modal="true" onClick={onClose}>
      <div className="glass-strong flex max-h-[90vh] w-full max-w-2xl flex-col overflow-y-auto rounded-2xl p-6"
        onClick={(e) => e.stopPropagation()}>
        <div className="flex items-start justify-between gap-3">
          <div>
            <h2 className="text-sm font-semibold text-ink-900">
              Branches — {tenant.tradeName ?? tenant.legalName}
            </h2>
            <p className="mt-0.5 text-xs text-ink-500">
              Every sale, receipt and journal is scoped to a branch. A new one gets its cash account
              straight away.
            </p>
          </div>
          <Button variant="ghost" size="sm" onClick={onClose} aria-label="Close">
            <X aria-hidden />
          </Button>
        </div>

        {error && (
          <div role="alert" className="mt-3 rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
            {error}
          </div>
        )}

        <div className="mt-4">
          {loading ? (
            <p className="py-6 text-center text-sm text-ink-400">
              <Loader2 className="mr-2 inline animate-spin" aria-hidden />Loading…
            </p>
          ) : branches.length === 0 ? (
            <p className="py-4 text-sm text-ink-400">No branches yet.</p>
          ) : (
            <ul className="space-y-1.5">
              {branches.map((b) => (
                <li key={b.id} className="flex flex-wrap items-center gap-2 rounded-lg border border-ink-200 px-3 py-2">
                  <span className="min-w-0 flex-1">
                    <span className="flex flex-wrap items-center gap-2">
                      <span className="text-sm text-ink-800">{b.name}</span>
                      {b.is_head_office && <Badge variant="info">Head office</Badge>}
                      <Badge variant={b.status === 'ACTIVE' ? 'positive' : 'warning'}>{b.status}</Badge>
                    </span>
                    <span className="block font-mono text-[11px] text-ink-400">
                      {b.code}{b.city ? ` · ${b.city}` : ''}{b.gstin ? ` · ${b.gstin}` : ''}
                    </span>
                  </span>
                  <Button variant="ghost" size="sm" disabled={pending}
                    onClick={() => {
                      setEditing(b.id);
                      setAdding(true);
                      setForm({
                        code: b.code, name: b.name, city: b.city ?? '', state: b.state ?? '',
                        stateCode: '', gstin: b.gstin ?? '', phone: '', isHeadOffice: b.is_head_office,
                      });
                    }}>
                    <Pencil aria-hidden />
                  </Button>
                  <Button variant="ghost" size="sm" disabled={pending}
                    onClick={() => toggle(b.id, b.status)}
                    title={b.status === 'ACTIVE' ? 'Suspend' : 'Reactivate'}>
                    {b.status === 'ACTIVE' ? 'Suspend' : 'Activate'}
                  </Button>
                </li>
              ))}
            </ul>
          )}
        </div>

        {adding ? (
          <div className="mt-4 rounded-xl border border-ink-200 bg-white/60 p-4">
            <h3 className="mb-3 text-[11px] font-semibold uppercase tracking-wide text-ink-500">
              {editing ? 'Edit branch' : 'Add a branch'}
            </h3>
            <div className="grid gap-3 sm:grid-cols-2">
              <div>
                <Label htmlFor="tb-code" className="mb-1.5 block">Code</Label>
                <Input id="tb-code" value={form.code} disabled={editing !== null}
                  onChange={set('code')} placeholder="NORTH" />
              </div>
              <div>
                <Label htmlFor="tb-name" className="mb-1.5 block">Name</Label>
                <Input id="tb-name" value={form.name} onChange={set('name')} placeholder="North Showroom" />
              </div>
              <div>
                <Label htmlFor="tb-city" className="mb-1.5 block">City</Label>
                <Input id="tb-city" value={form.city} onChange={set('city')} />
              </div>
              <div>
                <Label htmlFor="tb-statecode" className="mb-1.5 block">GST state code</Label>
                <Input id="tb-statecode" value={form.stateCode} onChange={set('stateCode')} placeholder="33" />
              </div>
              <div className="sm:col-span-2">
                <Label htmlFor="tb-gstin" className="mb-1.5 block">GSTIN</Label>
                <Input id="tb-gstin" value={form.gstin} onChange={set('gstin')} />
                <p className="mt-1 text-xs text-ink-400">A branch in another state files under its own.</p>
              </div>
            </div>
            <label className="mt-3 flex items-center gap-2 text-sm text-ink-700">
              <input type="checkbox" checked={form.isHeadOffice}
                onChange={(e) => setForm((f) => ({ ...f, isHeadOffice: e.target.checked }))} />
              Head office
            </label>
            <div className="mt-3 flex justify-end gap-2">
              <Button variant="secondary" size="sm" onClick={reset} disabled={pending}>Cancel</Button>
              <Button size="sm" onClick={save} disabled={pending}>
                {pending && <Loader2 className="animate-spin" aria-hidden />}
                {editing ? 'Save branch' : 'Add branch'}
              </Button>
            </div>
          </div>
        ) : (
          <div className="mt-4 flex justify-end">
            <Button size="sm" variant="secondary" onClick={() => setAdding(true)}>
              <Plus aria-hidden />
              Add branch
            </Button>
          </div>
        )}
      </div>
    </div>
  );
}
