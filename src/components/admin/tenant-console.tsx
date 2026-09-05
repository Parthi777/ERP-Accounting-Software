'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Check, Loader2, Mail, Plus, Trash2, TriangleAlert, X } from 'lucide-react';

import type { TenantRow, ReadinessCheck } from '@/server/services/org/provisioning-service';
import {
  provisionDealerAction,
  purgeDealerAction,
  resendOwnerInviteAction,
} from '@/server/services/org/provisioning-actions';
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
