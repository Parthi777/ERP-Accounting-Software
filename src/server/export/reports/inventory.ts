import { hasPermission } from '@/server/auth/tenant-context';
import {
  getStockLedger,
  getStockLots,
  type LedgerEntry,
  type StockLotRow,
} from '@/server/services/inventory/inventory-service';
import {
  getInventoryMovement,
  getInventoryStockReport,
  type InventoryMovementRow,
  type InventoryStockRow,
} from '@/server/services/reports/reports-service';
import { getVehicleTransfers, type VehicleTransferRow } from '@/server/services/vehicles/transfer-service';

import { defineReport, type AnyExportReport, type ExportColumn } from '../types';
import { EXPORT_ROW_CAP, branchParam, filterFact, monthParams, periodFact, truncation } from './params';

/**
 * Inventory exports — spec §28, §31, §34, §41.
 *
 * LOCAL and COMPANY stay separate everywhere, because merging them is exactly
 * what §28 forbids and because the two sources are usually bought at different
 * prices — a combined line hides both the quantity split and the valuation.
 */

export const inventoryReports: AnyExportReport[] = [
  defineReport<StockLotRow>({
    id: 'stock-lots',
    title: 'Accessory and spare stock',
    description: 'Quantity and value by item, branch and source. Spec §28.',
    permission: 'inventory.view',
    load: async (context, params) => {
      const itemType = (params.get('type') ?? 'ALL') as 'ACCESSORY' | 'SPARE' | 'ALL';
      const rows = await getStockLots({
        branchId: branchParam(context, params),
        itemType,
        q: params.get('q') ?? undefined,
        limit: EXPORT_ROW_CAP,
      });

      return {
        rows,
        truncatedAt: truncation(rows.length),
        facts: [filterFact('Item type', itemType, 'Accessories and spares')],
        notes: ['One row per item, branch and source — local and company lots are never merged (spec §28).'],
      };
    },
    columns: (context) => {
      const base: ExportColumn<StockLotRow>[] = [
        { key: 'code', header: 'Item code', width: 16, value: (row) => row.itemCode },
        { key: 'name', header: 'Item', width: 30, value: (row) => row.itemName },
        { key: 'type', header: 'Type', width: 12, value: (row) => row.itemType },
        { key: 'branch', header: 'Branch', width: 16, value: (row) => row.branchName },
        { key: 'source', header: 'Source', width: 10, value: (row) => row.source },
        { key: 'qty', header: 'Quantity', type: 'quantity', total: true, value: (row) => row.quantity },
      ];

      if (!hasPermission(context, 'inventory.view_cost')) return base;

      return [
        ...base,
        { key: 'avgCost', header: 'Average cost', type: 'money', value: (row) => row.averageCost },
        { key: 'value', header: 'Stock value', type: 'money', total: true, value: (row) => row.stockValue },
      ];
    },
  }),

  defineReport<LedgerEntry>({
    id: 'stock-ledger',
    title: 'Stock ledger',
    description: 'Every stock movement, immutable and traceable. Spec §34.',
    permission: 'inventory.ledger.view',
    orientation: 'landscape',
    load: async (context, params) => {
      const { from, to } = monthParams(params);
      const { entries, totals } = await getStockLedger({
        branchId: branchParam(context, params),
        itemId: params.get('item') ?? null,
        type: params.get('movement') ?? undefined,
        source: params.get('source') ?? undefined,
        from,
        to,
        limit: EXPORT_ROW_CAP,
      });

      return {
        rows: entries,
        truncatedAt: truncation(entries.length),
        facts: [
          periodFact(from, to),
          filterFact('Movement', params.get('movement'), 'All movements'),
          filterFact('Source', params.get('source'), 'Local and company'),
        ],
        notes: [
          `Received ${totals.received} units, issued ${totals.issued} units in the period.`,
          'Quantity is signed: positive receives, negative issues. The balance column is the lot balance recorded at the time of the movement.',
        ],
      };
    },
    columns: () => [
      { key: 'at', header: 'When', type: 'datetime', width: 17, value: (row) => row.at },
      { key: 'code', header: 'Item code', width: 15, value: (row) => row.itemCode },
      { key: 'name', header: 'Item', width: 26, value: (row) => row.itemName },
      { key: 'branch', header: 'Branch', width: 15, value: (row) => row.branchName },
      { key: 'source', header: 'Source', width: 10, value: (row) => row.source },
      { key: 'type', header: 'Movement', width: 15, value: (row) => row.type },
      { key: 'qty', header: 'Quantity', type: 'quantity', total: true, value: (row) => row.quantity },
      { key: 'unitCost', header: 'Unit cost', type: 'money', value: (row) => row.unitCost },
      { key: 'value', header: 'Value', type: 'money', total: true, value: (row) => row.value },
      { key: 'balance', header: 'Balance', type: 'quantity', value: (row) => row.balanceAfter },
      { key: 'reference', header: 'Reference', width: 18, value: (row) => row.referenceNumber },
      { key: 'narration', header: 'Narration', width: 26, value: (row) => row.narration ?? row.reason },
    ],
  }),

  defineReport<InventoryStockRow>({
    id: 'inventory-stock-summary',
    title: 'Inventory stock summary',
    description: 'Local and company split by item and branch. Spec §28, §41.',
    permission: 'reports.inventory.view',
    load: async (context, params) => {
      const itemType = params.get('type');
      const rows = await getInventoryStockReport({
        branchId: branchParam(context, params),
        itemType: itemType && itemType !== 'ALL' ? itemType : undefined,
      });
      return { rows, facts: [filterFact('Item type', itemType, 'Accessories and spares')] };
    },
    columns: () => [
      { key: 'code', header: 'Item code', width: 16, value: (row) => row.itemCode },
      { key: 'name', header: 'Item', width: 30, value: (row) => row.itemName },
      { key: 'type', header: 'Type', width: 12, value: (row) => row.itemType },
      { key: 'branch', header: 'Branch', width: 16, value: (row) => row.branchName },
      { key: 'local', header: 'Local qty', type: 'quantity', total: true, value: (row) => row.localQty },
      { key: 'company', header: 'Company qty', type: 'quantity', total: true, value: (row) => row.companyQty },
      { key: 'total', header: 'Total qty', type: 'quantity', total: true, value: (row) => row.totalQty },
      { key: 'value', header: 'Stock value', type: 'money', total: true, value: (row) => row.totalValue },
    ],
  }),

  defineReport<InventoryMovementRow>({
    id: 'inventory-movement',
    title: 'Inventory movement',
    description: 'Receipts, issues and closing position per item. Spec §41.',
    permission: 'reports.inventory.view',
    load: async (context, params) => {
      const { from, to } = monthParams(params);
      const rows = await getInventoryMovement({ from, to, branchId: branchParam(context, params) });
      return { rows, facts: [periodFact(from, to)] };
    },
    columns: () => [
      { key: 'code', header: 'Item code', width: 16, value: (row) => row.itemCode },
      { key: 'name', header: 'Item', width: 30, value: (row) => row.itemName },
      { key: 'type', header: 'Type', width: 12, value: (row) => row.itemType },
      { key: 'received', header: 'Received qty', type: 'quantity', total: true, value: (row) => row.receivedQty },
      { key: 'receivedValue', header: 'Received value', type: 'money', total: true, value: (row) => row.receivedValue },
      { key: 'issued', header: 'Issued qty', type: 'quantity', total: true, value: (row) => row.issuedQty },
      { key: 'issuedValue', header: 'Issued value', type: 'money', total: true, value: (row) => row.issuedValue },
      { key: 'closing', header: 'Closing qty', type: 'quantity', total: true, value: (row) => row.closingQty },
      { key: 'closingValue', header: 'Closing value', type: 'money', total: true, value: (row) => row.closingValue },
    ],
  }),

  defineReport<VehicleTransferRow>({
    id: 'vehicle-transfers',
    title: 'Vehicle transfers',
    description: 'Units moved between branches, and what is still in transit. Spec §35.',
    permission: 'vehicles.transfers.view',
    orientation: 'landscape',
    load: async (context, params) => {
      const status = params.get('status') ?? 'ALL';
      const rows = await getVehicleTransfers({
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
    columns: () => [
      { key: 'number', header: 'Transfer no.', width: 16, value: (row) => row.transferNumber },
      { key: 'dispatched', header: 'Dispatched', type: 'date', width: 13, value: (row) => row.dispatchedAt },
      { key: 'chassis', header: 'Chassis', width: 22, value: (row) => row.chassisNo },
      { key: 'model', header: 'Model', width: 22, value: (row) => row.modelLabel },
      { key: 'from', header: 'From branch', width: 18, value: (row) => row.fromBranchName },
      { key: 'to', header: 'To branch', width: 18, value: (row) => row.toBranchName },
      { key: 'received', header: 'Received', type: 'date', width: 13, value: (row) => row.receivedAt },
      { key: 'status', header: 'Status', width: 13, value: (row) => row.status },
      { key: 'remarks', header: 'Remarks', width: 26, value: (row) => row.remarks },
    ],
  }),
];
