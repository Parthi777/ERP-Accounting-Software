import { hasPermission } from '@/server/auth/tenant-context';
import {
  getBranchPerformance,
  getMarginReport,
  getSalesSummary,
  getVehicleStockReport,
  type BranchPerformanceRow,
  type MarginRow,
  type SalesSummaryRow,
  type VehicleStockRow,
} from '@/server/services/reports/reports-service';
import { getBookings, type BookingListRow } from '@/server/services/sales/booking-service';
import { getDeliveries, getSales, type DeliveryRow, type SaleListRow } from '@/server/services/sales/sale-service';

import { defineReport, type AnyExportReport, type ExportColumn } from '../types';
import { EXPORT_ROW_CAP, branchParam, filterFact, monthParams, periodFact, truncation } from './params';

/**
 * Sales, bookings and vehicle stock — spec §41.
 *
 * Cost and margin appear only where the session may see them (§52). The service
 * withholds the values regardless; dropping the columns as well keeps a cashier's
 * export from carrying a column of dashes that advertises what is being hidden
 * and how many rows have one.
 */

const GROUP_LABELS: Record<string, string> = {
  MODEL: 'Model',
  BRANCH: 'Branch',
  EMPLOYEE: 'Sales executive',
  DAY: 'Day',
};

export const salesReports: AnyExportReport[] = [
  defineReport<SaleListRow>({
    id: 'sales-register',
    title: 'Sales register',
    description: 'Invoice-by-invoice detail with payment and finance split. Spec §41.',
    permission: 'sales.view',
    orientation: 'landscape',
    load: async (context, params) => {
      const status = params.get('status') ?? 'ALL';
      const rows = await getSales({
        status,
        branchId: branchParam(context, params),
        q: params.get('q') ?? undefined,
        limit: EXPORT_ROW_CAP,
      });

      return {
        rows,
        truncatedAt: truncation(rows.length),
        facts: [
          filterFact('Status', status, 'All statuses'),
          ...(params.get('q') ? [{ label: 'Search', value: params.get('q') as string }] : []),
        ],
      };
    },
    columns: () => [
      { key: 'date', header: 'Date', type: 'date', width: 12, value: (row) => row.invoiceDate },
      { key: 'invoice', header: 'Invoice no.', width: 18, value: (row) => row.invoiceNumber },
      { key: 'customer', header: 'Customer', width: 26, value: (row) => row.customerName },
      { key: 'customerCode', header: 'Customer ID', width: 14, value: (row) => row.customerCode },
      { key: 'model', header: 'Model', width: 22, value: (row) => row.modelLabel },
      { key: 'chassis', header: 'Chassis', width: 22, value: (row) => row.chassisNo },
      { key: 'branch', header: 'Branch', width: 16, value: (row) => row.branchName },
      { key: 'total', header: 'Invoice total', type: 'money', total: true, value: (row) => row.totalAmount },
      { key: 'paid', header: 'Received', type: 'money', total: true, value: (row) => row.paidAmount },
      { key: 'finance', header: 'Financed', type: 'money', total: true, value: (row) => row.financeAmount },
      { key: 'balance', header: 'Balance', type: 'money', total: true, value: (row) => row.balanceAmount },
      { key: 'status', header: 'Status', width: 18, value: (row) => row.status },
    ],
  }),

  defineReport<SalesSummaryRow>({
    id: 'sales-summary',
    title: 'Sales summary',
    description: 'Posted and delivered invoices, grouped. Spec §41.',
    permission: 'reports.sales.view',
    load: async (context, params) => {
      const { from, to } = monthParams(params);
      const groupBy = params.get('group') ?? 'MODEL';
      const rows = await getSalesSummary({ from, to, groupBy, branchId: branchParam(context, params) });

      return {
        rows,
        facts: [periodFact(from, to), { label: 'Grouped by', value: GROUP_LABELS[groupBy] ?? groupBy }],
      };
    },
    columns: (context) => {
      const base: ExportColumn<SalesSummaryRow>[] = [
        { key: 'group', header: 'Group', width: 30, value: (row) => row.groupLabel },
        { key: 'units', header: 'Units', type: 'number', total: true, value: (row) => row.units },
        { key: 'gross', header: 'Gross', type: 'money', total: true, value: (row) => row.gross },
        { key: 'tax', header: 'Tax', type: 'money', total: true, value: (row) => row.tax },
      ];

      if (!hasPermission(context, 'reports.margin.view')) return base;

      return [
        ...base,
        { key: 'cost', header: 'Cost', type: 'money', total: true, value: (row) => row.cost ?? null },
        { key: 'margin', header: 'Margin', type: 'money', total: true, value: (row) => row.margin ?? null },
      ];
    },
  }),

  defineReport<DeliveryRow>({
    id: 'deliveries',
    title: 'Delivery register',
    description: 'Vehicles handed over, with who received them. Spec §19.',
    permission: 'sales.view',
    orientation: 'landscape',
    load: async (context, params) => {
      const rows = await getDeliveries({
        branchId: branchParam(context, params),
        q: params.get('q') ?? undefined,
        limit: EXPORT_ROW_CAP,
      });
      return { rows, truncatedAt: truncation(rows.length) };
    },
    columns: () => [
      { key: 'at', header: 'Delivered', type: 'datetime', width: 18, value: (row) => row.deliveredAt },
      { key: 'number', header: 'Delivery no.', width: 16, value: (row) => row.deliveryNumber },
      { key: 'invoice', header: 'Invoice no.', width: 18, value: (row) => row.invoiceNumber },
      { key: 'customer', header: 'Customer', width: 26, value: (row) => row.customerName },
      { key: 'model', header: 'Model', width: 22, value: (row) => row.modelLabel },
      { key: 'chassis', header: 'Chassis', width: 22, value: (row) => row.chassisNo },
      { key: 'branch', header: 'Branch', width: 16, value: (row) => row.branchName },
      { key: 'receivedBy', header: 'Received by', width: 22, value: (row) => row.receivedBy },
      { key: 'odometer', header: 'Odometer', type: 'quantity', width: 10, value: (row) => row.odometer },
    ],
  }),

  defineReport<BookingListRow>({
    id: 'bookings',
    title: 'Booking register',
    description: 'Bookings with advance received and conversion status. Spec §41.',
    permission: 'bookings.view',
    orientation: 'landscape',
    load: async (context, params) => {
      const status = params.get('status') ?? 'ALL';
      const rows = await getBookings({
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
      { key: 'date', header: 'Date', type: 'date', width: 12, value: (row) => row.bookingDate },
      { key: 'number', header: 'Booking no.', width: 16, value: (row) => row.bookingNumber },
      { key: 'customer', header: 'Customer', width: 26, value: (row) => row.customerName },
      { key: 'customerCode', header: 'Customer ID', width: 14, value: (row) => row.customerCode },
      { key: 'model', header: 'Model', width: 24, value: (row) => row.modelLabel },
      { key: 'branch', header: 'Branch', width: 16, value: (row) => row.branchName },
      { key: 'amount', header: 'Booking value', type: 'money', total: true, value: (row) => row.bookingAmount },
      { key: 'received', header: 'Advance received', type: 'money', total: true, value: (row) => row.receivedAmount },
      { key: 'expected', header: 'Expected delivery', type: 'date', width: 14, value: (row) => row.expectedDelivery },
      { key: 'status', header: 'Status', width: 12, value: (row) => row.status },
    ],
  }),

  defineReport<VehicleStockRow>({
    id: 'vehicle-stock',
    title: 'Vehicle stock and ageing',
    description: 'Chassis-level stock with days in hand. Spec §13, §41.',
    permission: 'reports.inventory.view',
    orientation: 'landscape',
    load: async (context, params) => {
      const rows = await getVehicleStockReport({ branchId: branchParam(context, params) });
      return { rows, notes: ['Ageing runs from the stock date, not the purchase invoice date.'] };
    },
    columns: (context) => {
      const base: ExportColumn<VehicleStockRow>[] = [
        { key: 'chassis', header: 'Chassis', width: 22, value: (row) => row.chassisNo },
        { key: 'brand', header: 'Brand', width: 12, value: (row) => row.brand },
        { key: 'model', header: 'Model', width: 20, value: (row) => row.modelName },
        { key: 'variant', header: 'Variant', width: 18, value: (row) => row.variantName },
        { key: 'branch', header: 'Branch', width: 16, value: (row) => row.branchName },
        { key: 'stockDate', header: 'In stock since', type: 'date', width: 14, value: (row) => row.stockDate },
        { key: 'age', header: 'Age (days)', type: 'number', width: 11, value: (row) => row.ageDays },
        { key: 'bucket', header: 'Ageing', width: 14, value: (row) => row.ageBucket },
        { key: 'status', header: 'Status', width: 18, value: (row) => row.status },
      ];

      if (!hasPermission(context, 'vehicles.view_cost')) return base;

      return [
        ...base,
        { key: 'cost', header: 'Purchase cost', type: 'money', total: true, value: (row) => row.purchaseCost ?? null },
      ];
    },
  }),

  defineReport<MarginRow>({
    id: 'margin',
    title: 'Margin report',
    description: 'Revenue against cost by stream. Owner and accounts only — spec §41, §52.',
    permission: 'reports.margin.view',
    load: async (context, params) => {
      const { from, to } = monthParams(params);
      const rows = await getMarginReport({ from, to, branchId: branchParam(context, params) });
      return { rows, facts: [periodFact(from, to)] };
    },
    columns: () => [
      { key: 'stream', header: 'Stream', width: 24, value: (row) => row.stream },
      { key: 'documents', header: 'Documents', type: 'number', total: true, value: (row) => row.documents },
      { key: 'revenue', header: 'Revenue', type: 'money', total: true, value: (row) => row.revenue },
      { key: 'cost', header: 'Cost', type: 'money', total: true, value: (row) => row.cost },
      { key: 'margin', header: 'Margin', type: 'money', total: true, value: (row) => row.margin },
      // Percentages do not add up, so this one is left out of the totals row.
      { key: 'percent', header: 'Margin %', type: 'percent', width: 10, value: (row) => row.marginPercent },
    ],
  }),

  defineReport<BranchPerformanceRow>({
    id: 'branch-performance',
    title: 'Branch performance',
    description: 'Sales, service, bookings and cash by branch. Spec §41, §43.',
    permission: 'reports.branch_performance.view',
    orientation: 'landscape',
    load: async (_context, params) => {
      const { from, to } = monthParams(params);
      const rows = await getBranchPerformance({ from, to });
      return {
        rows,
        facts: [periodFact(from, to)],
        notes: ['Cash in hand and receivables are balances as at the end of the period, not period movements.'],
      };
    },
    columns: (context) => {
      const base: ExportColumn<BranchPerformanceRow>[] = [
        { key: 'branch', header: 'Branch', width: 20, value: (row) => row.branchName },
        { key: 'code', header: 'Code', width: 10, value: (row) => row.branchCode },
        { key: 'units', header: 'Vehicles', type: 'number', total: true, value: (row) => row.vehicleUnits },
        { key: 'revenue', header: 'Vehicle revenue', type: 'money', total: true, value: (row) => row.vehicleRevenue },
        { key: 'jobs', header: 'Service jobs', type: 'number', total: true, value: (row) => row.serviceJobs },
        { key: 'serviceRevenue', header: 'Service revenue', type: 'money', total: true, value: (row) => row.serviceRevenue },
        { key: 'bookings', header: 'Open bookings', type: 'number', total: true, value: (row) => row.bookingsOpen },
        { key: 'advances', header: 'Booking advances', type: 'money', total: true, value: (row) => row.bookingAdvances },
        { key: 'cash', header: 'Cash in hand', type: 'money', total: true, value: (row) => row.cashInHand },
        { key: 'receivables', header: 'Receivables', type: 'money', total: true, value: (row) => row.receivables },
      ];

      if (!hasPermission(context, 'reports.margin.view')) return base;

      return [
        ...base,
        { key: 'cost', header: 'Cost', type: 'money', total: true, value: (row) => row.cost ?? null },
        { key: 'margin', header: 'Margin', type: 'money', total: true, value: (row) => row.margin ?? null },
      ];
    },
  }),
];
