'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Loader2 } from 'lucide-react';

import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { Input, Label } from '@/components/ui/input';
import { createPurchaseBillAction } from '@/server/services/purchases/purchase-actions';

/**
 * Opening a purchase bill — spec §24.
 *
 * Only the header. Lines are added on the bill itself, because a vehicle line
 * has to pick a chassis out of stock and that is a search, not a field.
 */
export function PurchaseBillForm({
  suppliers,
  today,
}: {
  readonly suppliers: readonly { id: string; label: string }[];
  readonly today: string;
}) {
  const router = useRouter();
  const [pending, startTransition] = React.useTransition();
  const [error, setError] = React.useState<string | null>(null);
  const [supplierId, setSupplierId] = React.useState('');
  const [supplierBillNumber, setSupplierBillNumber] = React.useState('');
  const [billDate, setBillDate] = React.useState(today);
  const [dueDate, setDueDate] = React.useState('');
  const [notes, setNotes] = React.useState('');

  const submit = (event: React.FormEvent) => {
    event.preventDefault();
    setError(null);

    if (!supplierId) return setError('Choose the supplier this bill is from.');
    if (!supplierBillNumber.trim()) return setError("Enter the supplier's own bill number.");
    if (dueDate && dueDate < billDate) return setError('The due date cannot be before the bill date.');

    startTransition(async () => {
      const result = await createPurchaseBillAction({
        supplierId,
        supplierBillNumber,
        billDate,
        dueDate: dueDate || null,
        notes: notes.trim() || null,
      });

      if (!result.ok || !result.id) {
        setError(result.error ?? 'The bill could not be created.');
        return;
      }
      router.push(`/purchases/${result.id}`);
    });
  };

  if (suppliers.length === 0) {
    return (
      <Panel className="p-6">
        <p className="text-sm text-ink-700">
          There are no active suppliers yet. Create one under Masters → Suppliers before entering a
          purchase bill — the bill has to say who it is owed to.
        </p>
      </Panel>
    );
  }

  return (
    <form onSubmit={submit} className="space-y-4" noValidate>
      {error && (
        <div role="alert" className="rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
          {error}
        </div>
      )}

      <Panel className="p-5">
        <h2 className="text-sm font-semibold text-ink-900">Bill header</h2>
        <p className="mb-4 text-xs text-ink-500">
          The bill opens as a draft. Nothing reaches the ledger until it is posted.
        </p>

        <div className="grid gap-4 sm:grid-cols-2">
          <div className="sm:col-span-2">
            <Label htmlFor="supplier" className="mb-1.5 block">
              Supplier<span className="ml-0.5 text-danger-600">*</span>
            </Label>
            <select
              id="supplier" value={supplierId} onChange={(e) => setSupplierId(e.target.value)}
              className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
            >
              <option value="">Choose a supplier</option>
              {suppliers.map((s) => <option key={s.id} value={s.id}>{s.label}</option>)}
            </select>
          </div>

          <div>
            <Label htmlFor="their-ref" className="mb-1.5 block">
              Supplier&rsquo;s bill number<span className="ml-0.5 text-danger-600">*</span>
            </Label>
            <Input
              id="their-ref" value={supplierBillNumber}
              onChange={(e) => setSupplierBillNumber(e.target.value)}
              placeholder="e.g. TVS/2026/8801" autoFocus
            />
            <p className="mt-1 text-xs text-ink-400">
              Ours is issued automatically. Keying the same one twice for a supplier is refused.
            </p>
          </div>

          <div>
            <Label htmlFor="bill-date" className="mb-1.5 block">
              Bill date<span className="ml-0.5 text-danger-600">*</span>
            </Label>
            <Input id="bill-date" type="date" value={billDate} onChange={(e) => setBillDate(e.target.value)} />
          </div>

          <div>
            <Label htmlFor="due-date" className="mb-1.5 block">Due date</Label>
            <Input id="due-date" type="date" value={dueDate} onChange={(e) => setDueDate(e.target.value)} />
          </div>

          <div className="sm:col-span-2">
            <Label htmlFor="notes" className="mb-1.5 block">Notes</Label>
            <Input id="notes" value={notes} onChange={(e) => setNotes(e.target.value)}
              placeholder="Optional — lorry receipt, delivery note, anything worth keeping" />
          </div>
        </div>
      </Panel>

      <Button type="submit" disabled={pending}>
        {pending && <Loader2 className="animate-spin" aria-hidden />}
        {pending ? 'Creating…' : 'Create draft'}
      </Button>
    </form>
  );
}
