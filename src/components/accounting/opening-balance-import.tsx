'use client';

import * as React from 'react';

import { CsvImport, type ImportColumn } from '@/components/forms/csv-import';
import { useIdempotencyKey } from '@/components/forms/use-idempotency-key';
import { Panel } from '@/components/ui/panel';
import { Label } from '@/components/ui/input';
import {
  commitOpeningBalancesAction,
  previewOpeningBalancesAction,
} from '@/server/services/accounting/opening-balance-actions';
import type {
  OpeningBalanceRow,
  PartyType,
} from '@/server/services/accounting/opening-balance-import';

const COLUMNS: readonly ImportColumn<OpeningBalanceRow>[] = [
  { header: 'Code', mono: true, render: (r) => r.party_code || '—' },
  { header: 'Name', render: (r) => r.party_name },
  { header: 'Amount', numeric: true, render: (r) => r.amount || '—' },
  { header: 'Direction', render: (r) => r.direction },
];

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
}: {
  readonly customerTemplate: string;
  readonly supplierTemplate: string;
}) {
  const [partyType, setPartyType] = React.useState<PartyType>('CUSTOMER');
  const [asOn, setAsOn] = React.useState(() => new Date().toISOString().slice(0, 10));

  // Scoped to the party type and date, so posting customers then suppliers are
  // two documents — and re-posting either one replays rather than doubling.
  const idempotency = useIdempotencyKey(`opening:${partyType}:${asOn}`);

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
              className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
            >
              <option value="CUSTOMER">Customers (receivable)</option>
              <option value="SUPPLIER">Suppliers (payable)</option>
            </select>
          </div>
          <div>
            <Label htmlFor="as-on" className="mb-1.5 block">As at</Label>
            <input
              id="as-on"
              type="date"
              value={asOn}
              onChange={(e) => setAsOn(e.target.value)}
              className="h-9 rounded-lg border border-ink-200 bg-white px-3 text-sm shadow-sm"
            />
          </div>
          <p className="flex-1 text-xs text-ink-500">
            The day before you start trading here. Every balance is dated to it, so nothing appears
            to have happened in this system before the cut-over.
          </p>
        </div>
      </Panel>

      <CsvImport<OpeningBalanceRow>
        // Remounts on either change, so a preview built for customers cannot be
        // confirmed against suppliers.
        key={`${partyType}:${asOn}`}
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
    </div>
  );
}
