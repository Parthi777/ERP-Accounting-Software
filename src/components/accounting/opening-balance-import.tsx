'use client';

import * as React from 'react';

import { CsvImport, type ImportColumn } from '@/components/forms/csv-import';
import { useIdempotencyKey } from '@/components/forms/use-idempotency-key';
import { Panel } from '@/components/ui/panel';
import { Label } from '@/components/ui/input';
import {
  commitOpeningBalancesAction,
  commitOpeningBillsAction,
  previewOpeningBalancesAction,
  previewOpeningBillsAction,
} from '@/server/services/accounting/opening-balance-actions';
import type {
  OpeningBalanceRow,
  OpeningBillRow,
  PartyType,
} from '@/server/services/accounting/opening-balance-import';

const COLUMNS: readonly ImportColumn<OpeningBalanceRow>[] = [
  { header: 'Code', mono: true, render: (r) => r.party_code || '—' },
  { header: 'Name', render: (r) => r.party_name },
  { header: 'Amount', numeric: true, render: (r) => r.amount || '—' },
  { header: 'Direction', render: (r) => r.direction },
];

const BILL_COLUMNS: readonly ImportColumn<OpeningBillRow>[] = [
  { header: 'Code', mono: true, render: (r) => r.party_code || '—' },
  { header: 'Name', render: (r) => r.party_name },
  { header: 'Bill', mono: true, render: (r) => r.bill_reference || '—' },
  { header: 'Dated', render: (r) => r.bill_date || '—' },
  { header: 'Due', render: (r) => r.due_date || '—' },
  { header: 'Open amount', numeric: true, render: (r) => r.amount || '—' },
];

type Mode = 'PARTY' | 'BILL';

/**
 * Cut-over balances (spec §24).
 *
 * Party type and as-on date sit outside the file rather than in it. Both are one
 * decision for the whole cut-over, and a column repeating the same value on
 * every row is a column that will eventually disagree with itself.
 */
export function OpeningBalanceImport({
  customerTemplate,
  supplierTemplate,
  customerBillTemplate,
  supplierBillTemplate,
}: {
  readonly customerTemplate: string;
  readonly supplierTemplate: string;
  readonly customerBillTemplate: string;
  readonly supplierBillTemplate: string;
}) {
  const [partyType, setPartyType] = React.useState<PartyType>('CUSTOMER');
  const [mode, setMode] = React.useState<Mode>('PARTY');
  const [asOn, setAsOn] = React.useState(() => new Date().toISOString().slice(0, 10));

  // Scoped to the party type and date, so posting customers then suppliers are
  // two documents — and re-posting either one replays rather than doubling.
  const idempotency = useIdempotencyKey(`opening:${mode}:${partyType}:${asOn}`);

  return (
    <div className="space-y-4">
      <Panel className="p-4">
        <div className="flex flex-wrap items-end gap-4">
          <div>
            <Label htmlFor="party-type" className="mb-1.5 block">Ledger</Label>
            <select
              id="party-type"
              value={partyType}
              onChange={(e) => setPartyType(e.target.value as PartyType)}
              className="h-9 field px-3 text-sm"
            >
              <option value="CUSTOMER">Customers (receivable)</option>
              <option value="SUPPLIER">Suppliers (payable)</option>
            </select>
          </div>
          <div>
            <Label htmlFor="ob-mode" className="mb-1.5 block">Detail</Label>
            <select
              id="ob-mode"
              value={mode}
              onChange={(e) => setMode(e.target.value as Mode)}
              className="h-9 field px-3 text-sm"
            >
              <option value="PARTY">One balance per party</option>
              <option value="BILL">Bill-wise (each unpaid bill)</option>
            </select>
          </div>
          <div>
            <Label htmlFor="as-on" className="mb-1.5 block">As at</Label>
            <input
              id="as-on"
              type="date"
              value={asOn}
              onChange={(e) => setAsOn(e.target.value)}
              className="h-9 field px-3 text-sm"
            />
          </div>
          <p className="flex-1 text-xs text-ink-500">
            The day before you start trading here. Every balance is dated to it, so nothing appears
            to have happened in this system before the cut-over.
          </p>
        </div>
      </Panel>

      {mode === 'PARTY' ? (
        <CsvImport<OpeningBalanceRow>
          // Remounts on any change, so a preview built for customers cannot be
          // confirmed against suppliers.
          key={`${mode}:${partyType}:${asOn}`}
          noun="balance"
          pluralNoun="balances"
          columnHelp={
            'Two columns: party_code and amount. A positive amount means the party owes the ' +
            'dealer; a negative one means the dealer owes the party.'
          }
          templateFilename={`opening-balances-${partyType.toLowerCase()}.csv`}
          templateContent={partyType === 'CUSTOMER' ? customerTemplate : supplierTemplate}
          columns={COLUMNS}
          onPreview={(csv) => previewOpeningBalancesAction(partyType, csv)}
          onCommit={async (csv) => {
            const result = await commitOpeningBalancesAction(partyType, csv, asOn, idempotency.key());
            if (result.ok) idempotency.renew();
            return result;
          }}
          doneHref="/accounting/trial-balance"
          doneLabel="View trial balance"
          doneNote="Posted as one journal against 3300 Opening Balance Equity. Check the trial balance, then clear 3300 into retained earnings once the figures match your old system."
        />
      ) : (
        <CsvImport<OpeningBillRow>
          key={`${mode}:${partyType}:${asOn}`}
          noun="bill"
          pluralNoun="bills"
          columnHelp={
            'One row per unpaid bill: party_code, bill_reference, bill_date and amount (the part still ' +
            'open, always positive); due_date is optional. Dates as YYYY-MM-DD. Customers\' bills are what ' +
            'they owe; suppliers\' bills are what the dealer owes. Each bill is then settled and aged on its own.'
          }
          templateFilename={`opening-bills-${partyType.toLowerCase()}.csv`}
          templateContent={partyType === 'CUSTOMER' ? customerBillTemplate : supplierBillTemplate}
          columns={BILL_COLUMNS}
          onPreview={(csv) => previewOpeningBillsAction(partyType, csv, asOn)}
          onCommit={async (csv) => {
            const result = await commitOpeningBillsAction(partyType, csv, asOn, idempotency.key());
            if (result.ok) idempotency.renew();
            return result;
          }}
          doneHref="/accounting/ageing"
          doneLabel="View ageing"
          doneNote="Posted as one journal against 3300 Opening Balance Equity, one line per bill. Receipts and payments can now be allocated bill by bill."
        />
      )}
    </div>
  );
}
