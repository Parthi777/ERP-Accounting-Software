'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Check, Loader2, Send, Truck, Wallet } from 'lucide-react';

import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { Input, Label } from '@/components/ui/input';
import { cn } from '@/lib/utils';
import {
  deliverSaleAction,
  postSaleAction,
  recordPaymentAction,
  transitionSaleAction,
} from '@/server/services/sales/sale-actions';

type Action = 'submit' | 'verify' | 'approve' | 'reject' | 'cancel';

/**
 * The workflow strip on a sale — spec §19.
 *
 * Only the actions legal from the current status are offered, and only those the
 * session holds the permission for. The database enforces the order regardless;
 * this keeps a Cashier from being shown an Approve button that would only fail.
 */
export function SaleWorkflow({
  saleId,
  status,
  balanceDue,
  can,
}: {
  readonly saleId: string;
  readonly status: string;
  readonly balanceDue: number;
  readonly can: Readonly<Record<string, boolean>>;
}) {
  const router = useRouter();
  const [error, setError] = React.useState<string | null>(null);
  const [pending, startTransition] = React.useTransition();
  const [dialog, setDialog] = React.useState<'reject' | 'cancel' | 'payment' | 'deliver' | null>(null);
  const [reason, setReason] = React.useState('');
  const [amount, setAmount] = React.useState('');
  const [mode, setMode] = React.useState('CASH');
  const [reference, setReference] = React.useState('');
  const [receivedBy, setReceivedBy] = React.useState('');

  const run = (fn: () => Promise<{ ok: boolean; error?: string }>) => {
    setError(null);
    startTransition(async () => {
      const result = await fn();
      if (!result.ok) {
        setError(result.error ?? 'That action could not be completed.');
        return;
      }
      setDialog(null);
      setReason('');
      setAmount('');
      setReference('');
      router.refresh();
    });
  };

  const move = (action: Action, why?: string) => run(() => transitionSaleAction(saleId, action, why));

  // Which transitions are legal from here (spec §19).
  const available: { action: Action; label: string; tone: 'primary' | 'secondary' | 'danger'; icon?: typeof Send }[] = [];

  if (status === 'DRAFT' && can.submit) {
    available.push({ action: 'submit', label: 'Submit for verification', tone: 'primary', icon: Send });
  }
  if (status === 'SUBMITTED' && can.verify) {
    available.push({ action: 'verify', label: 'Begin verification', tone: 'primary', icon: Check });
  }
  if (status === 'ACCOUNTS_VERIFICATION' && can.approve) {
    available.push({ action: 'approve', label: 'Approve', tone: 'primary', icon: Check });
  }
  if ((status === 'SUBMITTED' || status === 'ACCOUNTS_VERIFICATION') && can.verify) {
    available.push({ action: 'reject', label: 'Return for correction', tone: 'secondary' });
  }
  if (['DRAFT', 'SUBMITTED', 'ACCOUNTS_VERIFICATION', 'APPROVED'].includes(status) && can.cancel) {
    available.push({ action: 'cancel', label: 'Cancel', tone: 'danger' });
  }

  const showPost = status === 'APPROVED' && can.post;
  const showPayment = (status === 'POSTED' || status === 'DELIVERED') && can.create && balanceDue > 0;
  const showDeliver = status === 'POSTED' && can.deliver;

  if (available.length === 0 && !showPost && !showPayment && !showDeliver) {
    return error ? (
      <div role="alert" className="rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
        {error}
      </div>
    ) : null;
  }

  return (
    <>
      <Panel className="p-4">
        {error && (
          <div role="alert" className="mb-3 rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
            {error}
          </div>
        )}

        <div className="flex flex-wrap items-center gap-2">
          {available.map((a) => (
            <Button
              key={a.action}
              variant={a.tone === 'primary' ? 'primary' : a.tone === 'danger' ? 'danger' : 'secondary'}
              size="sm"
              disabled={pending}
              onClick={() => (a.action === 'reject' || a.action === 'cancel' ? setDialog(a.action) : move(a.action))}
            >
              {pending && <Loader2 className="animate-spin" aria-hidden />}
              {a.icon && !pending && <a.icon aria-hidden />}
              {a.label}
            </Button>
          ))}

          {showPost && (
            <Button size="sm" disabled={pending} onClick={() => run(() => postSaleAction(saleId))}>
              {pending && <Loader2 className="animate-spin" aria-hidden />}
              Post to accounts
            </Button>
          )}

          {showPayment && (
            <Button variant="secondary" size="sm" onClick={() => setDialog('payment')} disabled={pending}>
              <Wallet aria-hidden />
              Record payment
            </Button>
          )}

          {showDeliver && (
            <Button size="sm" onClick={() => setDialog('deliver')} disabled={pending}>
              <Truck aria-hidden />
              Deliver
            </Button>
          )}
        </div>

        {status === 'APPROVED' && can.post && (
          <p className="mt-2 text-xs text-ink-500">
            Posting writes the journal, relieves stock, recognises COGS and moves the vehicle — all in one
            transaction. Any failure leaves nothing changed.
          </p>
        )}
      </Panel>

      {dialog && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-ink-900/25 p-4 backdrop-blur-sm"
          role="dialog" aria-modal="true" onClick={() => setDialog(null)}>
          <div className="glass-strong w-full max-w-md rounded-2xl p-6" onClick={(e) => e.stopPropagation()}>
            {(dialog === 'reject' || dialog === 'cancel') && (
              <>
                <h2 className="text-sm font-semibold text-ink-900">
                  {dialog === 'reject' ? 'Return this sale for correction?' : 'Cancel this sale?'}
                </h2>
                <p className="mt-1 text-sm text-ink-600">
                  {dialog === 'reject'
                    ? 'It goes back to draft so the cashier can fix it.'
                    : 'A cancelled sale cannot be reopened. The reason is recorded in the audit trail.'}
                </p>
                <label className="mt-4 block">
                  <span className="text-sm font-medium text-ink-700">Reason</span>
                  <textarea rows={3} value={reason} onChange={(e) => setReason(e.target.value)}
                    className="mt-1 w-full rounded-lg border border-ink-200 bg-white px-3 py-2 text-sm shadow-sm" />
                </label>
                <div className="mt-4 flex justify-end gap-2">
                  <Button variant="secondary" size="sm" onClick={() => setDialog(null)} disabled={pending}>Back</Button>
                  <Button
                    variant={dialog === 'cancel' ? 'danger' : 'primary'}
                    size="sm"
                    disabled={pending || (dialog === 'cancel' && !reason.trim())}
                    onClick={() => move(dialog, reason.trim() || undefined)}
                  >
                    {pending && <Loader2 className="animate-spin" aria-hidden />}
                    {dialog === 'reject' ? 'Return it' : 'Cancel sale'}
                  </Button>
                </div>
              </>
            )}

            {dialog === 'payment' && (
              <>
                <h2 className="text-sm font-semibold text-ink-900">Record a payment</h2>
                <p className="mt-1 text-sm text-ink-600">
                  Posts a receipt and its journal entry together.
                </p>
                <div className="mt-4 space-y-3">
                  <div>
                    <Label htmlFor="pay-amount" className="mb-1.5 block">Amount</Label>
                    <Input id="pay-amount" type="number" step="0.01" min="0" value={amount}
                      onChange={(e) => setAmount(e.target.value)} placeholder={String(balanceDue / 100)} />
                  </div>
                  <div>
                    <Label htmlFor="pay-mode" className="mb-1.5 block">Mode</Label>
                    <select id="pay-mode" value={mode} onChange={(e) => setMode(e.target.value)}
                      className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm">
                      {['CASH', 'UPI', 'CARD', 'NEFT', 'RTGS', 'IMPS', 'CHEQUE', 'DD', 'FINANCE'].map((m) => (
                        <option key={m} value={m}>{m}</option>
                      ))}
                    </select>
                  </div>
                  <div>
                    <Label htmlFor="pay-ref" className="mb-1.5 block">Reference</Label>
                    <Input id="pay-ref" value={reference} onChange={(e) => setReference(e.target.value)} />
                  </div>
                </div>
                <div className="mt-4 flex justify-end gap-2">
                  <Button variant="secondary" size="sm" onClick={() => setDialog(null)} disabled={pending}>Cancel</Button>
                  <Button size="sm" disabled={pending || !(Number(amount) > 0)}
                    onClick={() => run(() => recordPaymentAction(saleId, Number(amount), mode, reference || undefined))}>
                    {pending && <Loader2 className="animate-spin" aria-hidden />}
                    Record payment
                  </Button>
                </div>
              </>
            )}

            {dialog === 'deliver' && (
              <>
                <h2 className="text-sm font-semibold text-ink-900">Record delivery</h2>
                <p className="mt-1 text-sm text-ink-600">
                  The vehicle moves to DELIVERED. That is terminal — it cannot return to stock.
                </p>
                <div className="mt-4 space-y-3">
                  <div>
                    <Label htmlFor="received-by" className="mb-1.5 block">Received by</Label>
                    <Input id="received-by" value={receivedBy} onChange={(e) => setReceivedBy(e.target.value)}
                      placeholder="Name of the person taking delivery" />
                  </div>
                </div>
                {balanceDue > 0 && (
                  <p className="mt-3 rounded-lg border border-warning-200 bg-warning-50 px-3 py-2 text-xs text-warning-800">
                    There is still a balance outstanding on this invoice. Delivering is allowed, but the
                    receivable stays open.
                  </p>
                )}
                <div className="mt-4 flex justify-end gap-2">
                  <Button variant="secondary" size="sm" onClick={() => setDialog(null)} disabled={pending}>Cancel</Button>
                  <Button size="sm" disabled={pending}
                    onClick={() => run(() => deliverSaleAction(saleId, receivedBy || undefined))}>
                    {pending && <Loader2 className="animate-spin" aria-hidden />}
                    Confirm delivery
                  </Button>
                </div>
              </>
            )}
          </div>
        </div>
      )}
    </>
  );
}

/** The workflow as a visible progression, so the current step is obvious. */
export function SaleProgress({ status }: { readonly status: string }) {
  const steps = ['DRAFT', 'SUBMITTED', 'ACCOUNTS_VERIFICATION', 'APPROVED', 'POSTED', 'DELIVERED'];
  const labels = ['Draft', 'Submitted', 'Verification', 'Approved', 'Posted', 'Delivered'];
  const current = steps.indexOf(status);

  if (status === 'CANCELLED' || status === 'RETURNED') {
    return null;
  }

  return (
    <ol className="flex flex-wrap items-center gap-1 text-xs">
      {steps.map((step, i) => (
        <li key={step} className="flex items-center gap-1">
          <span
            className={cn(
              'rounded-md px-2 py-1',
              i < current && 'bg-positive-50 text-positive-700',
              i === current && 'bg-brand-600 font-medium text-white',
              i > current && 'bg-ink-100 text-ink-400',
            )}
          >
            {labels[i]}
          </span>
          {i < steps.length - 1 && <span className="text-ink-300">›</span>}
        </li>
      ))}
    </ol>
  );
}
