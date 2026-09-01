'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import Link from 'next/link';
import { Loader2, Save } from 'lucide-react';

import { Panel } from '@/components/ui/panel';
import { Button } from '@/components/ui/button';
import { Input, Label } from '@/components/ui/input';
import { createJobCardAction } from '@/server/services/service/service-actions';

interface Option {
  readonly id: string;
  readonly label: string;
}

const SERVICE_TYPES = [
  { value: 'PAID', label: 'Paid service' },
  { value: 'FREE', label: 'Free service' },
  { value: 'WARRANTY', label: 'Warranty' },
  { value: 'ACCIDENT', label: 'Accident repair' },
  { value: 'RUNNING_REPAIR', label: 'Running repair' },
];

/**
 * Booking a vehicle in — spec §32.
 *
 * The complaint is what the customer said, in their words. It is separate from
 * the diagnosis the technician records later, because the two disagreeing is
 * often the useful part of the record.
 */
export function JobCardForm({
  customers,
  employees,
  branchName,
}: {
  readonly customers: readonly Option[];
  readonly employees: readonly Option[];
  readonly branchName: string;
}) {
  const router = useRouter();
  const [error, setError] = React.useState<string | null>(null);
  const [pending, startTransition] = React.useTransition();

  const [customerId, setCustomerId] = React.useState('');
  const [serviceType, setServiceType] = React.useState('PAID');
  const [registrationNo, setRegistrationNo] = React.useState('');
  const [odometer, setOdometer] = React.useState('');
  const [complaint, setComplaint] = React.useState('');
  const [advisorId, setAdvisorId] = React.useState('');
  const [technicianId, setTechnicianId] = React.useState('');
  const [promisedAt, setPromisedAt] = React.useState('');

  const submit = (event: React.FormEvent) => {
    event.preventDefault();
    setError(null);

    if (!customerId) return setError('Choose a customer.');
    if (!complaint.trim()) return setError('Record what the customer reported.');

    startTransition(async () => {
      const result = await createJobCardAction({
        customerId,
        serviceType,
        registrationNo: registrationNo.trim().toUpperCase() || null,
        odometer: odometer ? Number(odometer) : null,
        complaint: complaint.trim(),
        serviceAdvisorId: advisorId || null,
        technicianId: technicianId || null,
        promisedAt: promisedAt ? new Date(promisedAt).toISOString() : null,
      });

      if (!result.ok) {
        setError(result.error ?? 'The job card could not be created.');
        return;
      }
      router.push('/service');
      router.refresh();
    });
  };

  return (
    <form onSubmit={submit} className="space-y-4" noValidate>
      {error && (
        <div role="alert" className="rounded-lg border border-danger-200 bg-danger-50 px-3 py-2 text-sm text-danger-700">
          {error}
        </div>
      )}

      <Panel className="p-5">
        <h2 className="text-sm font-semibold text-ink-900">Customer and vehicle</h2>
        <p className="mb-4 text-xs text-ink-500">Booking in at {branchName}.</p>

        <div className="grid gap-4 sm:grid-cols-2">
          <div className="sm:col-span-2">
            <Label htmlFor="customer" className="mb-1.5 block">
              Customer<span className="ml-0.5 text-danger-600">*</span>
            </Label>
            <select id="customer" value={customerId} onChange={(e) => setCustomerId(e.target.value)}
              className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm">
              <option value="">Choose a customer</option>
              {customers.map((c) => <option key={c.id} value={c.id}>{c.label}</option>)}
            </select>
            <p className="mt-1 text-xs text-ink-400">
              Not listed?{' '}
              <Link href="/customers/new" className="text-brand-600 hover:underline">Create the customer first</Link>.
            </p>
          </div>

          <div>
            <Label htmlFor="registration" className="mb-1.5 block">Registration number</Label>
            <Input id="registration" value={registrationNo} placeholder="TN 01 AB 1234"
              onChange={(e) => setRegistrationNo(e.target.value)} className="uppercase" />
          </div>

          <div>
            <Label htmlFor="odometer" className="mb-1.5 block">Odometer (km)</Label>
            <Input id="odometer" type="number" min="0" step="1" value={odometer}
              onChange={(e) => setOdometer(e.target.value)} />
          </div>
        </div>
      </Panel>

      <Panel className="p-5">
        <h2 className="mb-4 text-sm font-semibold text-ink-900">The job</h2>

        <div className="grid gap-4 sm:grid-cols-2">
          <div>
            <Label htmlFor="type" className="mb-1.5 block">Service type</Label>
            <select id="type" value={serviceType} onChange={(e) => setServiceType(e.target.value)}
              className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm">
              {SERVICE_TYPES.map((t) => <option key={t.value} value={t.value}>{t.label}</option>)}
            </select>
          </div>

          <div>
            <Label htmlFor="promised" className="mb-1.5 block">Promised by</Label>
            <Input id="promised" type="datetime-local" value={promisedAt}
              onChange={(e) => setPromisedAt(e.target.value)} />
          </div>

          <div className="sm:col-span-2">
            <Label htmlFor="complaint" className="mb-1.5 block">
              Customer complaint<span className="ml-0.5 text-danger-600">*</span>
            </Label>
            <textarea id="complaint" rows={3} value={complaint} onChange={(e) => setComplaint(e.target.value)}
              placeholder="What the customer reported, in their words"
              className="w-full rounded-lg border border-ink-200 bg-white px-3 py-2 text-sm shadow-sm" />
          </div>

          <div>
            <Label htmlFor="advisor" className="mb-1.5 block">Service advisor</Label>
            <select id="advisor" value={advisorId} onChange={(e) => setAdvisorId(e.target.value)}
              className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm">
              <option value="">Not assigned</option>
              {employees.map((e) => <option key={e.id} value={e.id}>{e.label}</option>)}
            </select>
          </div>

          <div>
            <Label htmlFor="technician" className="mb-1.5 block">Technician</Label>
            <select id="technician" value={technicianId} onChange={(e) => setTechnicianId(e.target.value)}
              className="h-9 w-full rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm">
              <option value="">Not assigned</option>
              {employees.map((e) => <option key={e.id} value={e.id}>{e.label}</option>)}
            </select>
          </div>
        </div>
      </Panel>

      <div className="flex items-center gap-2">
        <Button type="submit" disabled={pending}>
          {pending ? <Loader2 className="animate-spin" aria-hidden /> : <Save aria-hidden />}
          {pending ? 'Creating…' : 'Open job card'}
        </Button>
        <Button variant="secondary" asChild><Link href="/service">Cancel</Link></Button>
      </div>
    </form>
  );
}
