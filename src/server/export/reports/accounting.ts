import { formatDate } from '@/lib/format';
import { subtract, ZERO, type Paise } from '@/lib/money';
import {
  getBalanceSheet,
  getChartOfAccounts,
  getJournals,
  getProfitAndLoss,
  getTrialBalance,
  type ChartAccount,
  type JournalSummary,
  type SourceModule,
  type StatementRow,
  type TrialBalanceRow,
} from '@/server/services/accounting/accounting-service';
import { getCustomerLedger, getSupplierLedger, type LedgerLine } from '@/server/services/accounting/ledger-service';

import { defineReport, type AnyExportReport } from '../types';
import { EXPORT_ROW_CAP, branchParam, dateParam, monthParams, periodFact, truncation } from './params';

/**
 * Accounting exports — spec §41.
 *
 * These are the statements a dealer's auditor asks for, so the detail matters
 * more than the presentation. The journal register in particular is the
 * line-by-line one: a summary of journals is of no use to anyone checking the
 * books, which is the only reason someone exports a journal register at all.
 */

export const accountingReports: AnyExportReport[] = [
  defineReport<TrialBalanceRow>({
    id: 'trial-balance',
    title: 'Trial balance',
    description: 'Closing debit and credit by account. Spec §41.',
    permission: 'accounting.reports.view',
    load: async (context, params) => {
      const asOn = dateParam(params, 'asOn');
      const rows = await getTrialBalance(asOn, branchParam(context, params));
      const debit = rows.reduce((sum, row) => sum + row.debit, 0);
      const credit = rows.reduce((sum, row) => sum + row.credit, 0);

      return {
        rows,
        facts: [{ label: 'As on', value: formatDate(asOn) }],
        notes: [
          debit === credit
            ? 'Debits equal credits — the ledger balances.'
            : `OUT OF BALANCE by ${Math.abs(debit - credit) / 100} — this should never happen; raise it with your accountant.`,
        ],
      };
    },
    columns: () => [
      { key: 'code', header: 'Code', width: 10, value: (row) => row.code },
      { key: 'name', header: 'Account', width: 34, value: (row) => row.name },
      { key: 'type', header: 'Type', width: 12, value: (row) => row.type },
      { key: 'debit', header: 'Debit', type: 'money', total: true, value: (row) => row.debit },
      { key: 'credit', header: 'Credit', type: 'money', total: true, value: (row) => row.credit },
    ],
  }),

  defineReport<StatementRow>({
    id: 'profit-and-loss',
    title: 'Profit and loss',
    description: 'Income and expenses for the period. Spec §41.',
    permission: 'accounting.reports.view',
    load: async (context, params) => {
      const { from, to } = monthParams(params);
      const rows = await getProfitAndLoss(from, to, branchParam(context, params));

      const income = rows
        .filter((row) => row.section === 'INCOME')
        .reduce((sum, row) => sum + row.amount, 0) as Paise;
      const expense = rows
        .filter((row) => row.section === 'EXPENSE')
        .reduce((sum, row) => sum + row.amount, 0) as Paise;

      return {
        rows,
        facts: [periodFact(from, to)],
        notes: [
          `Income ${money(income)} less expenses ${money(expense)} = ${money(subtract(income, expense))} for the period.`,
        ],
      };
    },
    columns: () => [
      { key: 'section', header: 'Section', width: 14, value: (row) => row.section },
      { key: 'code', header: 'Code', width: 10, value: (row) => row.code },
      { key: 'name', header: 'Account', width: 36, value: (row) => row.name },
      { key: 'amount', header: 'Amount', type: 'money', total: true, value: (row) => row.amount },
    ],
  }),

  defineReport<StatementRow>({
    id: 'balance-sheet',
    title: 'Balance sheet',
    description: 'Assets, liabilities and equity as on a date. Spec §41.',
    permission: 'accounting.reports.view',
    load: async (context, params) => {
      const asOn = dateParam(params, 'asOn');
      const rows = await getBalanceSheet(asOn, branchParam(context, params));

      const assets = rows
        .filter((row) => row.section === 'ASSET')
        .reduce((sum, row) => sum + row.amount, 0) as Paise;
      const rest = rows
        .filter((row) => row.section !== 'ASSET')
        .reduce((sum, row) => sum + row.amount, 0) as Paise;

      return {
        rows,
        facts: [{ label: 'As on', value: formatDate(asOn) }],
        notes: [
          `Assets ${money(assets)} against liabilities, equity and retained result ${money(rest)}.`,
          'The total row below sums every section and is therefore not meaningful on its own.',
        ],
      };
    },
    columns: () => [
      { key: 'section', header: 'Section', width: 14, value: (row) => row.section },
      { key: 'code', header: 'Code', width: 10, value: (row) => row.code },
      { key: 'name', header: 'Account', width: 36, value: (row) => row.name },
      { key: 'amount', header: 'Amount', type: 'money', value: (row) => row.amount },
    ],
  }),

  defineReport<JournalSummary>({
    id: 'journal-register',
    title: 'Journal register',
    description: 'Every journal entry posted in the period. Spec §21, §41.',
    permission: 'accounting.journals.view',
    orientation: 'landscape',
    load: async (context, params) => {
      const { from, to } = monthParams(params);
      const sourceModule = params.get('module');
      const status = params.get('status');

      const rows = await getJournals({
        from,
        to,
        branchId: branchParam(context, params),
        module: sourceModule && sourceModule !== 'ALL' ? (sourceModule as SourceModule) : null,
        status: status && status !== 'ALL' ? (status as 'DRAFT' | 'POSTED' | 'REVERSED') : null,
        limit: EXPORT_ROW_CAP,
      });

      return {
        rows,
        truncatedAt: truncation(rows.length),
        facts: [
          periodFact(from, to),
          { label: 'Module', value: sourceModule && sourceModule !== 'ALL' ? sourceModule : 'All modules' },
          { label: 'Status', value: status && status !== 'ALL' ? status : 'All statuses' },
        ],
      };
    },
    columns: () => [
      { key: 'date', header: 'Date', type: 'date', width: 12, value: (row) => row.entryDate },
      { key: 'number', header: 'Entry no.', width: 16, value: (row) => row.entryNumber },
      { key: 'module', header: 'Module', width: 14, value: (row) => row.sourceModule },
      { key: 'branch', header: 'Branch', width: 16, value: (row) => row.branchName },
      { key: 'narration', header: 'Narration', width: 40, value: (row) => row.narration },
      { key: 'status', header: 'Status', width: 12, value: (row) => row.status },
      { key: 'amount', header: 'Amount', type: 'money', total: true, value: (row) => row.totalDebit },
    ],
  }),

  defineReport<ChartAccount>({
    id: 'chart-of-accounts',
    title: 'Chart of accounts',
    description: 'Every ledger account and its classification. Spec §24.',
    permission: 'accounting.coa.view',
    load: async () => ({ rows: await getChartOfAccounts() }),
    columns: () => [
      { key: 'code', header: 'Code', width: 10, value: (row) => row.code },
      { key: 'name', header: 'Account', width: 36, value: (row) => row.name },
      { key: 'type', header: 'Type', width: 14, value: (row) => row.type },
      { key: 'normal', header: 'Normal balance', width: 14, value: (row) => row.normalBalance },
      { key: 'group', header: 'Group', width: 8, value: (row) => (row.isGroup ? 'Yes' : 'No') },
      { key: 'system', header: 'System', width: 8, value: (row) => (row.isSystem ? 'Yes' : 'No') },
      { key: 'status', header: 'Status', width: 10, value: (row) => row.status },
    ],
  }),

  defineReport<LedgerLine>({
    id: 'customer-ledger',
    title: 'Customer ledger',
    description: 'Every posting against one customer, with a running balance. Spec §41.',
    permission: 'accounting.ledgers.view',
    load: async (_context, params) => {
      const { from, to } = monthParams(params);
      const customerId = params.get('customer');

      if (!customerId) {
        return { rows: [], notes: ['No customer was selected, so there is nothing to report.'] };
      }

      const ledger = await getCustomerLedger({ customerId, from, to });
      if (!ledger) {
        return { rows: [], notes: ['That customer could not be found.'] };
      }

      return {
        rows: ledger.lines,
        facts: [
          { label: 'Customer', value: `${ledger.partyName} (${ledger.partyCode})` },
          periodFact(from, to),
          { label: 'Opening', value: money(ledger.opening) },
          { label: 'Closing', value: money(ledger.closing) },
        ],
        notes: [
          `Opening ${money(ledger.opening)}, debits ${money(ledger.totalDebit)}, credits ${money(ledger.totalCredit)}, closing ${money(ledger.closing)}.`,
          'The balance column runs from the opening balance, so it continues the ledger rather than restarting at zero.',
        ],
      };
    },
    columns: () => ledgerColumns(),
  }),

  defineReport<LedgerLine>({
    id: 'supplier-ledger',
    title: 'Supplier ledger',
    description: 'Every posting against one supplier, with a running balance. Spec §41.',
    permission: 'accounting.ledgers.view',
    load: async (_context, params) => {
      const { from, to } = monthParams(params);
      const supplierId = params.get('supplier');

      if (!supplierId) {
        return { rows: [], notes: ['No supplier was selected, so there is nothing to report.'] };
      }

      const ledger = await getSupplierLedger({ supplierId, from, to });
      if (!ledger) {
        return { rows: [], notes: ['That supplier could not be found.'] };
      }

      return {
        rows: ledger.lines,
        facts: [
          { label: 'Supplier', value: `${ledger.partyName} (${ledger.partyCode})` },
          periodFact(from, to),
          { label: 'Opening', value: money(ledger.opening) },
          { label: 'Closing', value: money(ledger.closing) },
        ],
        notes: [
          `Opening ${money(ledger.opening)}, debits ${money(ledger.totalDebit)}, credits ${money(ledger.totalCredit)}, closing ${money(ledger.closing)}.`,
        ],
      };
    },
    columns: () => ledgerColumns(),
  }),
];

function ledgerColumns() {
  return [
    { key: 'date', header: 'Date', type: 'date' as const, width: 12, value: (row: LedgerLine) => row.date },
    { key: 'entry', header: 'Entry no.', width: 16, value: (row: LedgerLine) => row.entryNumber },
    { key: 'narration', header: 'Narration', width: 44, value: (row: LedgerLine) => row.narration },
    { key: 'debit', header: 'Debit', type: 'money' as const, total: true, value: (row: LedgerLine) => row.debit },
    { key: 'credit', header: 'Credit', type: 'money' as const, total: true, value: (row: LedgerLine) => row.credit },
    // Deliberately not totalled: a running balance summed down the column is a
    // meaningless number that looks like a real one.
    { key: 'balance', header: 'Balance', type: 'money' as const, value: (row: LedgerLine) => row.balance },
  ];
}

function money(value: Paise): string {
  return new Intl.NumberFormat('en-IN', {
    style: 'currency',
    currency: 'INR',
    minimumFractionDigits: 2,
  }).format((value ?? ZERO) / 100);
}
