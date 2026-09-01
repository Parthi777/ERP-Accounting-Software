import { formatDate } from '@/lib/format';
import { getBankAccounts, getBankBook, type BankEntry } from '@/server/services/bank/bank-service';
import { getCashDay, type CashEntry } from '@/server/services/cash/cash-service';
import {
  getGstDocuments,
  getHsnSummary,
  type GstDocumentRow,
  type HsnSummaryRow,
} from '@/server/services/gst/gst-service';
import {
  getCounterInvoices,
  getJobCards,
  getServiceInvoices,
  type JobCardRow,
  type ServiceInvoiceRow,
} from '@/server/services/service/service-service';

import { defineReport, type AnyExportReport } from '../types';
import { EXPORT_ROW_CAP, branchParam, dateParam, filterFact, monthParams, periodFact, truncation } from './params';

/**
 * Cash, bank, GST and service — spec §32, §33, §37, §38, §41.
 */

export const operationsReports: AnyExportReport[] = [
  defineReport<CashEntry>({
    id: 'cash-book',
    title: 'Daily cash book',
    description: 'Every receipt and payment for one day, with a running balance. Spec §37.',
    permission: 'cashbook.view',
    load: async (context, params) => {
      const date = dateParam(params, 'date');
      const day = await getCashDay({ date, branchId: branchParam(context, params) });

      if (!day) {
        return {
          rows: [],
          facts: [{ label: 'Date', value: formatDate(date) }],
          notes: ['No cash day exists for this branch and date.'],
        };
      }

      return {
        rows: day.entries,
        facts: [
          { label: 'Date', value: formatDate(day.businessDate) },
          { label: 'Branch', value: day.branchName },
          { label: 'Status', value: day.status },
        ],
        notes: [
          `Opening ${rupees(day.opening)} + receipts ${rupees(day.receipts)} − payments ${rupees(day.payments)} = expected closing ${rupees(day.expectedClosing)}.`,
          day.physicalCash !== null
            ? `Counted ${rupees(day.physicalCash)}, difference ${rupees(day.difference ?? 0)}.`
            : 'The day has not been counted yet, so there is no difference to report.',
          ...(day.remarks ? [`Remarks: ${day.remarks}`] : []),
        ],
      };
    },
    columns: () => [
      { key: 'time', header: 'Time', type: 'datetime', width: 17, value: (row) => row.time },
      { key: 'reference', header: 'Reference', width: 18, value: (row) => row.reference },
      { key: 'particular', header: 'Particular', width: 42, value: (row) => row.particular },
      { key: 'receipt', header: 'Receipt', type: 'money', total: true, value: (row) => row.receipt },
      { key: 'payment', header: 'Payment', type: 'money', total: true, value: (row) => row.payment },
      { key: 'balance', header: 'Balance', type: 'money', value: (row) => row.balance },
    ],
  }),

  defineReport<BankEntry>({
    id: 'bank-book',
    title: 'Bank book',
    description: 'Movements on one bank account, with reconciliation state. Spec §38, §39.',
    permission: 'bank.book.view',
    orientation: 'landscape',
    load: async (_context, params) => {
      const { from, to } = monthParams(params);
      const requested = params.get('account');

      // The account must be one this session can actually see; getBankAccounts
      // is already tenant-scoped, so resolving through it is the check.
      const accounts = await getBankAccounts();
      const account = accounts.find((a) => a.id === requested) ?? accounts[0];

      if (!account) {
        return { rows: [], notes: ['No bank account is configured for this dealer.'] };
      }

      const rows = await getBankBook({ bankAccountId: account.id, from, to });

      return {
        rows,
        facts: [
          { label: 'Account', value: `${account.name} — ${account.bankName}` },
          periodFact(from, to),
        ],
        notes: ['The reconciled column reflects the statement match state at the time of export (spec §39).'],
      };
    },
    columns: () => [
      { key: 'date', header: 'Date', type: 'date', width: 12, value: (row) => row.date },
      { key: 'particular', header: 'Particular', width: 40, value: (row) => row.particular },
      { key: 'reference', header: 'Reference', width: 18, value: (row) => row.reference },
      { key: 'utr', header: 'UTR', width: 20, value: (row) => row.utr },
      { key: 'receipt', header: 'Receipt', type: 'money', total: true, value: (row) => row.receipt },
      { key: 'payment', header: 'Payment', type: 'money', total: true, value: (row) => row.payment },
      { key: 'balance', header: 'Balance', type: 'money', value: (row) => row.balance },
      { key: 'reconciled', header: 'Reconciled', width: 11, value: (row) => (row.reconciled ? 'Yes' : 'No') },
    ],
  }),

  defineReport<GstDocumentRow>({
    id: 'gst-register',
    title: 'GST document register',
    description: 'Every taxable document with its tax split and IRN. Spec §41.',
    permission: 'gst.reports.view',
    orientation: 'landscape',
    load: async (context, params) => {
      const { from, to } = monthParams(params);
      const section = params.get('section');
      const rows = await getGstDocuments({
        from,
        to,
        branchId: branchParam(context, params),
        section: section && section !== 'ALL' ? section : undefined,
      });

      return {
        rows,
        facts: [periodFact(from, to), filterFact('Section', section, 'All sections')],
        notes: ['Tax values are those stored on the document, not recomputed from the current tax master (spec §16).'],
      };
    },
    columns: () => [
      { key: 'date', header: 'Date', type: 'date', width: 12, value: (row) => row.documentDate },
      { key: 'number', header: 'Document no.', width: 18, value: (row) => row.documentNumber },
      { key: 'type', header: 'Type', width: 14, value: (row) => row.documentType },
      { key: 'customer', header: 'Customer', width: 24, value: (row) => row.customerName },
      { key: 'gstin', header: 'GSTIN', width: 18, value: (row) => row.gstin },
      { key: 'pos', header: 'Place of supply', width: 15, value: (row) => row.placeOfSupply },
      { key: 'section', header: 'Section', width: 10, value: (row) => row.section },
      { key: 'taxable', header: 'Taxable value', type: 'money', total: true, value: (row) => row.taxableValue },
      { key: 'cgst', header: 'CGST', type: 'money', total: true, value: (row) => row.cgst },
      { key: 'sgst', header: 'SGST', type: 'money', total: true, value: (row) => row.sgst },
      { key: 'igst', header: 'IGST', type: 'money', total: true, value: (row) => row.igst },
      { key: 'total', header: 'Invoice value', type: 'money', total: true, value: (row) => row.invoiceValue },
      { key: 'einvoice', header: 'E-invoice', width: 12, value: (row) => row.einvoiceStatus },
      { key: 'irn', header: 'IRN', width: 30, value: (row) => row.irn },
    ],
  }),

  defineReport<HsnSummaryRow>({
    id: 'gst-hsn-summary',
    title: 'GST HSN summary',
    description: 'Taxable value and tax by HSN, for the GSTR-1 HSN table. Spec §41.',
    permission: 'gst.reports.view',
    load: async (context, params) => {
      const { from, to } = monthParams(params);
      const rows = await getHsnSummary({ from, to, branchId: branchParam(context, params) });
      return { rows, facts: [periodFact(from, to)] };
    },
    columns: () => [
      { key: 'hsn', header: 'HSN / SAC', width: 14, value: (row) => row.hsnCode },
      { key: 'description', header: 'Description', width: 34, value: (row) => row.description },
      { key: 'documents', header: 'Documents', type: 'number', total: true, value: (row) => row.documentCount },
      { key: 'taxable', header: 'Taxable value', type: 'money', total: true, value: (row) => row.taxableValue },
      { key: 'cgst', header: 'CGST', type: 'money', total: true, value: (row) => row.cgst },
      { key: 'sgst', header: 'SGST', type: 'money', total: true, value: (row) => row.sgst },
      { key: 'igst', header: 'IGST', type: 'money', total: true, value: (row) => row.igst },
      { key: 'totalTax', header: 'Total tax', type: 'money', total: true, value: (row) => row.totalTax },
    ],
  }),

  defineReport<ServiceInvoiceRow>({
    id: 'service-invoices',
    title: 'Service invoice register',
    description: 'Workshop invoices with payment status. Spec §32.',
    permission: 'service.jobcards.view',
    orientation: 'landscape',
    load: async (context, params) => {
      const status = params.get('status') ?? 'ALL';
      const rows = await getServiceInvoices({
        status,
        branchId: branchParam(context, params),
        limit: EXPORT_ROW_CAP,
      });
      return {
        rows,
        truncatedAt: truncation(rows.length),
        facts: [filterFact('Status', status, 'All statuses')],
      };
    },
    columns: () => serviceInvoiceColumns(),
  }),

  defineReport<ServiceInvoiceRow>({
    id: 'counter-sales',
    title: 'Counter sales register',
    description: 'Over-the-counter accessory and spare invoices. Spec §33.',
    permission: 'inventory.counter_sale.create',
    orientation: 'landscape',
    load: async (context, params) => {
      const status = params.get('status') ?? 'ALL';
      const rows = await getCounterInvoices({
        status,
        branchId: branchParam(context, params),
        limit: EXPORT_ROW_CAP,
      });
      return {
        rows,
        truncatedAt: truncation(rows.length),
        facts: [filterFact('Status', status, 'All statuses')],
      };
    },
    columns: () => serviceInvoiceColumns(),
  }),

  defineReport<JobCardRow>({
    id: 'job-cards',
    title: 'Job card register',
    description: 'Workshop jobs, their complaint and where they got to. Spec §32.',
    permission: 'service.jobcards.view',
    orientation: 'landscape',
    load: async (context, params) => {
      const status = params.get('status') ?? 'ALL';
      const rows = await getJobCards({
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
    columns: () => [
      { key: 'date', header: 'Date', type: 'date', width: 12, value: (row) => row.jobDate },
      { key: 'number', header: 'Job card no.', width: 16, value: (row) => row.number },
      { key: 'customer', header: 'Customer', width: 24, value: (row) => row.customerName },
      { key: 'registration', header: 'Registration', width: 15, value: (row) => row.registrationNo },
      { key: 'type', header: 'Type', width: 10, value: (row) => row.serviceType },
      { key: 'complaint', header: 'Complaint', width: 34, value: (row) => row.complaint },
      { key: 'advisor', header: 'Advisor', width: 18, value: (row) => row.advisorName },
      { key: 'branch', header: 'Branch', width: 15, value: (row) => row.branchName },
      { key: 'status', header: 'Status', width: 12, value: (row) => row.status },
      { key: 'invoice', header: 'Invoice no.', width: 16, value: (row) => row.invoiceNumber },
      { key: 'invoiceTotal', header: 'Invoice total', type: 'money', total: true, value: (row) => row.invoiceTotal },
    ],
  }),
];

function serviceInvoiceColumns() {
  return [
    { key: 'date', header: 'Date', type: 'date' as const, width: 12, value: (row: ServiceInvoiceRow) => row.invoiceDate },
    { key: 'number', header: 'Invoice no.', width: 18, value: (row: ServiceInvoiceRow) => row.number },
    { key: 'customer', header: 'Customer', width: 26, value: (row: ServiceInvoiceRow) => row.customerName },
    { key: 'jobCard', header: 'Job card', width: 16, value: (row: ServiceInvoiceRow) => row.jobCardNumber },
    { key: 'branch', header: 'Branch', width: 16, value: (row: ServiceInvoiceRow) => row.branchName },
    { key: 'total', header: 'Invoice total', type: 'money' as const, total: true, value: (row: ServiceInvoiceRow) => row.total },
    { key: 'paid', header: 'Received', type: 'money' as const, total: true, value: (row: ServiceInvoiceRow) => row.paid },
    { key: 'balance', header: 'Balance', type: 'money' as const, total: true, value: (row: ServiceInvoiceRow) => row.balance },
    { key: 'status', header: 'Status', width: 12, value: (row: ServiceInvoiceRow) => row.status },
  ];
}

function rupees(value: number): string {
  return new Intl.NumberFormat('en-IN', {
    style: 'currency',
    currency: 'INR',
    minimumFractionDigits: 2,
  }).format(value / 100);
}
