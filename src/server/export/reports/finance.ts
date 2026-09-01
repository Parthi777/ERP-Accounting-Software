import { hasPermission } from '@/server/auth/tenant-context';
import {
  getFinanceApplications,
  getFinanceCompanyBalances,
  getFinanceCompanyLedger,
  getFinanceSettlements,
  type FinanceApplicationRow,
  type FinanceCompanyBalance,
  type FinanceLedgerLine,
  type SettlementRow,
} from '@/server/services/finance/finance-service';
import { getFinanceSummary, type FinanceSummaryRow } from '@/server/services/reports/reports-service';

import { defineReport, type AnyExportReport, type ExportColumn } from '../types';
import { EXPORT_ROW_CAP, branchParam, filterFact, monthParams, periodFact, truncation } from './params';

/**
 * Finance and HP — spec §25, §26, §27, §41.
 *
 * Every report here is per finance company. Spec §25 is explicit that companies
 * are never pooled into one balance, and an export is exactly where that would
 * be tempting: a single "finance receivable" figure looks tidy and is useless,
 * because the dealer settles with each company separately.
 *
 * Commission is restricted (`finance.commission.view`). The service returns null
 * for it when the session may not see it; the column is dropped here to match.
 */

export const financeReports: AnyExportReport[] = [
  defineReport<FinanceApplicationRow>({
    id: 'finance-applications',
    title: 'Finance applications',
    description: 'HP applications with approval and disbursement status. Spec §27.',
    permission: 'finance.applications.view',
    orientation: 'landscape',
    load: async (context, params) => {
      const status = params.get('status') ?? 'ALL';
      const rows = await getFinanceApplications({
        status,
        branchId: branchParam(context, params),
        q: params.get('q') ?? undefined,
        limit: EXPORT_ROW_CAP,
      });
      return {
        rows,
        truncatedAt: truncation(rows.length),
        facts: [filterFact('Status', status, 'All statuses')],
      };
    },
    columns: (context) => {
      const base: ExportColumn<FinanceApplicationRow>[] = [
        { key: 'date', header: 'Date', type: 'date', width: 12, value: (row) => row.applicationDate },
        { key: 'number', header: 'Application no.', width: 17, value: (row) => row.applicationNumber },
        { key: 'customer', header: 'Customer', width: 24, value: (row) => row.customerName },
        { key: 'company', header: 'Finance company', width: 24, value: (row) => row.companyName },
        { key: 'chassis', header: 'Chassis', width: 21, value: (row) => row.chassisNo },
        { key: 'branch', header: 'Branch', width: 15, value: (row) => row.branchName },
        { key: 'loan', header: 'Loan amount', type: 'money', total: true, value: (row) => row.loanAmount },
        { key: 'down', header: 'Down payment', type: 'money', total: true, value: (row) => row.downPayment },
        { key: 'approved', header: 'Approved', type: 'money', total: true, value: (row) => row.approvedAmount },
        { key: 'disbursed', header: 'Disbursed', type: 'money', total: true, value: (row) => row.disbursedAmount },
        { key: 'pending', header: 'Pending', type: 'money', total: true, value: (row) => row.pendingAmount },
        { key: 'approval', header: 'Approval', width: 12, value: (row) => row.approvalStatus },
        { key: 'disbursement', header: 'Disbursement', width: 13, value: (row) => row.disbursementStatus },
        { key: 'dd', header: 'DD / reference', width: 18, value: (row) => row.ddNumber ?? row.bankReference },
      ];

      if (!hasPermission(context, 'finance.commission.view')) return base;

      return [
        ...base,
        { key: 'commission', header: 'Commission', type: 'money', total: true, value: (row) => row.commissionAmount },
      ];
    },
  }),

  defineReport<FinanceSummaryRow>({
    id: 'finance-summary',
    title: 'Finance summary',
    description: 'Units, amounts and pending disbursement by company. Spec §41.',
    permission: 'reports.finance.view',
    orientation: 'landscape',
    load: async (context, params) => {
      const { from, to } = monthParams(params);
      const rows = await getFinanceSummary({ from, to, branchId: branchParam(context, params) });
      return { rows, facts: [periodFact(from, to)] };
    },
    columns: (context) => {
      const base: ExportColumn<FinanceSummaryRow>[] = [
        { key: 'company', header: 'Finance company', width: 26, value: (row) => row.financeCompanyName },
        { key: 'applications', header: 'Applications', type: 'number', total: true, value: (row) => row.applications },
        { key: 'approved', header: 'Approved', type: 'number', total: true, value: (row) => row.approved },
        { key: 'rejected', header: 'Rejected', type: 'number', total: true, value: (row) => row.rejected },
        { key: 'pending', header: 'Pending', type: 'number', total: true, value: (row) => row.pending },
        { key: 'loan', header: 'Loan amount', type: 'money', total: true, value: (row) => row.loanAmount },
        { key: 'disbursed', header: 'Disbursed', type: 'money', total: true, value: (row) => row.disbursed },
        {
          key: 'pendingDisbursement',
          header: 'Pending disbursement',
          type: 'money',
          total: true,
          value: (row) => row.pendingDisbursement,
        },
      ];

      if (!hasPermission(context, 'finance.commission.view')) return base;

      return [
        ...base,
        { key: 'commission', header: 'Commission', type: 'money', total: true, value: (row) => row.financeCommission ?? null },
      ];
    },
  }),

  defineReport<FinanceCompanyBalance>({
    id: 'finance-balances',
    title: 'Finance company balances',
    description: 'Closing position per company. Never pooled — spec §25.',
    permission: 'finance.trade_advance.view',
    load: async () => ({
      rows: await getFinanceCompanyBalances(),
      notes: [
        'A positive balance means the company owes the dealer; a negative balance means the dealer holds an unadjusted advance.',
      ],
    }),
    columns: () => [
      { key: 'code', header: 'Code', width: 14, value: (row) => row.code },
      { key: 'name', header: 'Finance company', width: 34, value: (row) => row.name },
      { key: 'balance', header: 'Balance', type: 'money', total: true, value: (row) => row.balance },
    ],
  }),

  defineReport<FinanceLedgerLine>({
    id: 'finance-company-ledger',
    title: 'Finance company ledger',
    description: 'Every movement against one company, with a running balance. Spec §26.',
    permission: 'finance.trade_advance.view',
    orientation: 'landscape',
    load: async (_context, params) => {
      const { from, to } = monthParams(params);
      const companyId = params.get('company');

      if (!companyId || companyId === 'ALL') {
        return { rows: [], notes: ['No finance company was selected, so there is nothing to report.'] };
      }

      const ledger = await getFinanceCompanyLedger({ companyId, from, to });
      if (!ledger) {
        return { rows: [], notes: ['That finance company could not be found.'] };
      }

      return {
        rows: ledger.lines,
        facts: [
          { label: 'Finance company', value: ledger.companyName },
          periodFact(from, to),
        ],
        notes: [
          `Opening ${rupees(ledger.opening)}, debits ${rupees(ledger.totalDebit)}, credits ${rupees(ledger.totalCredit)}, closing ${rupees(ledger.closing)}.`,
        ],
      };
    },
    columns: () => [
      { key: 'date', header: 'Date', type: 'date', width: 12, value: (row) => row.date },
      { key: 'type', header: 'Type', width: 20, value: (row) => row.type },
      { key: 'reference', header: 'Reference', width: 20, value: (row) => row.referenceNumber },
      { key: 'narration', header: 'Narration', width: 36, value: (row) => row.narration },
      { key: 'debit', header: 'Debit', type: 'money', total: true, value: (row) => row.debit },
      { key: 'credit', header: 'Credit', type: 'money', total: true, value: (row) => row.credit },
      { key: 'balance', header: 'Balance', type: 'money', value: (row) => row.balance },
    ],
  }),

  defineReport<SettlementRow>({
    id: 'finance-settlements',
    title: 'Finance settlements',
    description: 'Gross, commission, deductions and net per settlement. Spec §26.',
    permission: 'finance.settlements.manage',
    orientation: 'landscape',
    load: async (_context, params) => {
      const status = params.get('status') ?? 'ALL';
      const rows = await getFinanceSettlements(status, EXPORT_ROW_CAP);
      return {
        rows,
        truncatedAt: truncation(rows.length),
        facts: [filterFact('Status', status, 'All statuses')],
        notes: ['Net = gross less commission less deductions.'],
      };
    },
    columns: (context) => {
      const base: ExportColumn<SettlementRow>[] = [
        { key: 'date', header: 'Date', type: 'date', width: 12, value: (row) => row.settlementDate },
        { key: 'number', header: 'Settlement no.', width: 17, value: (row) => row.settlementNumber },
        { key: 'company', header: 'Finance company', width: 26, value: (row) => row.companyName },
        { key: 'from', header: 'Period from', type: 'date', width: 13, value: (row) => row.fromDate },
        { key: 'to', header: 'Period to', type: 'date', width: 13, value: (row) => row.toDate },
        { key: 'gross', header: 'Gross', type: 'money', total: true, value: (row) => row.grossAmount },
        { key: 'deductions', header: 'Deductions', type: 'money', total: true, value: (row) => row.deductions },
        { key: 'net', header: 'Net', type: 'money', total: true, value: (row) => row.netAmount },
        { key: 'status', header: 'Status', width: 11, value: (row) => row.status },
      ];

      if (!hasPermission(context, 'finance.commission.view')) return base;

      // Slotted before Net so the arithmetic reads left to right on the page.
      const netIndex = base.findIndex((column) => column.key === 'net');
      return [
        ...base.slice(0, netIndex),
        { key: 'commission', header: 'Commission', type: 'money', total: true, value: (row) => row.commissionAmount },
        ...base.slice(netIndex),
      ];
    },
  }),
];

function rupees(value: number): string {
  return new Intl.NumberFormat('en-IN', {
    style: 'currency',
    currency: 'INR',
    minimumFractionDigits: 2,
  }).format(value / 100);
}
