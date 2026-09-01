import 'server-only';

import { requirePermission, type TenantContext } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { fromDb, type Paise } from '@/lib/money';
import { parseCsv } from '@/lib/csv';
import { recordAudit } from '@/server/services/audit/record-audit';

/**
 * Accessory and spare stock movements — spec §34, §35, §60.16, §60.22.
 *
 * Two operations live here and they share a principle: stock is never written
 * to directly. Both post movements into `inventory_transactions`, and the
 * on-hand figure follows from the ledger by trigger. That is what makes a
 * quantity answerable — every unit can be traced to the movement that put it
 * there.
 *
 * The LOCAL/COMPANY split survives both. A local lot transferred to another
 * branch arrives as local stock; an adjustment names the lot it corrects.
 * Merging them would destroy the distinction spec §60.16 exists to keep.
 */

export type StockSource = 'LOCAL' | 'COMPANY';

export interface StockLotRow {
  readonly itemId: string;
  readonly itemCode: string;
  readonly itemName: string;
  readonly itemType: string;
  readonly branchId: string;
  readonly branchName: string;
  readonly source: StockSource;
  readonly quantity: number;
  readonly averageCost: Paise;
  readonly stockValue: Paise;
}

export interface InventoryResult {
  readonly ok: boolean;
  readonly error?: string;
  readonly message?: string;
}

function resolveBranch(context: TenantContext, requested: string | null): string | null {
  if (!requested) {
    return context.hasAllBranchAccess ? null : (context.activeBranch?.id ?? null);
  }
  return context.accessibleBranches.some((b) => b.id === requested)
    ? requested
    : (context.activeBranch?.id ?? null);
}

/**
 * The stock lots a user can act on. Returned for both screens, because a
 * transfer and an adjustment both need to start from what is actually there —
 * offering an item with no stock is how impossible quantities get typed in.
 */
export async function getStockLots(params: {
  readonly branchId: string | null;
  readonly itemType?: 'ACCESSORY' | 'SPARE' | 'ALL';
  readonly q?: string;
  /**
   * Row cap. Defaults to the screen's, which is all anyone scrolls; the
   * report exporter raises it, because a spreadsheet has no such limit and a
   * silently truncated financial extract is worse than none.
   */
  readonly limit?: number;
}): Promise<StockLotRow[]> {
  const context = await requirePermission('inventory.view');
  const supabase = await createSupabaseServerClient();

  let query = supabase
    .from('inventory_stock')
    .select(
      'item_id, branch_id, source, quantity, average_cost, stock_value, inventory_items!inner ( item_code, name, item_type ), branches!inner ( name )',
    )
    .order('quantity', { ascending: false })
    .limit(params.limit ?? 1000);

  const branchId = resolveBranch(context, params.branchId);
  if (branchId) {
    query = query.eq('branch_id', branchId);
  }
  if (params.itemType && params.itemType !== 'ALL') {
    query = query.eq('inventory_items.item_type', params.itemType);
  }

  const { data, error } = await query;
  if (error) {
    throw new Error(`Failed to load stock: ${error.message}`);
  }

  const term = params.q?.trim().toLowerCase();

  // Cost and stock value are restricted (spec §60.19). Drop them here rather
  // than hiding them in the table, so they never reach the browser for a role
  // without the permission.
  const maySeeCost = context.permissions.has('inventory.view_cost');

  return (data ?? [])
    .map((row) => ({
      itemId: row.item_id,
      itemCode: row.inventory_items.item_code,
      itemName: row.inventory_items.name,
      itemType: row.inventory_items.item_type,
      branchId: row.branch_id,
      branchName: row.branches.name,
      source: row.source as StockSource,
      quantity: Number(row.quantity),
      averageCost: maySeeCost ? fromDb(row.average_cost) : (0 as Paise),
      stockValue: maySeeCost ? fromDb(row.stock_value) : (0 as Paise),
    }))
    .filter(
      (row) =>
        !term ||
        row.itemCode.toLowerCase().includes(term) ||
        row.itemName.toLowerCase().includes(term),
    );
}

export async function transferStock(input: {
  readonly itemId: string;
  readonly fromBranchId: string;
  readonly toBranchId: string;
  readonly quantity: number;
  readonly source: StockSource;
  readonly remarks?: string | null;
}): Promise<InventoryResult> {
  const context = await requirePermission('inventory.stock.transfer');
  const supabase = await createSupabaseServerClient();

  if (!input.itemId) {
    return { ok: false, error: 'Choose the item to transfer.' };
  }
  if (!(input.quantity > 0)) {
    return { ok: false, error: 'Enter a quantity greater than zero.' };
  }
  if (input.fromBranchId === input.toBranchId) {
    return { ok: false, error: 'The source and destination branches are the same.' };
  }
  for (const branchId of [input.fromBranchId, input.toBranchId]) {
    if (!context.accessibleBranches.some((b) => b.id === branchId)) {
      return { ok: false, error: 'That is not a branch you can transfer between.' };
    }
  }

  const { error } = await supabase.rpc('transfer_inventory_stock', {
    p_item_id: input.itemId,
    p_from_branch_id: input.fromBranchId,
    p_to_branch_id: input.toBranchId,
    p_quantity: input.quantity,
    p_source: input.source,
    p_remarks: input.remarks?.trim() || null,
  });

  if (error) {
    console.error('[inventory] transfer failed', error.message);
    return { ok: false, error: describeInventoryError(error.message) };
  }

  await recordAudit({
    action: 'UPDATE',
    entityType: 'inventory_stock',
    entityId: input.itemId,
    dealerId: context.dealerId,
    branchId: input.fromBranchId,
    userId: context.userId,
    userEmail: context.email,
    newData: {
      transferred: input.quantity,
      source: input.source,
      from_branch_id: input.fromBranchId,
      to_branch_id: input.toBranchId,
    },
    reason: input.remarks?.trim() || undefined,
  });

  return {
    ok: true,
    message: `${input.quantity} moved as ${input.source.toLowerCase()} stock. Both branches show the movement in their ledger.`,
  };
}

/**
 * Corrects a lot against a physical count — spec §34, §60.22.
 *
 * The reason is not a formality. An adjustment without one is indistinguishable
 * from shrinkage, and the ledger exists so the figure can be questioned later.
 * The database refuses a blank reason too; this check exists to say so in a
 * sentence rather than as a constraint violation.
 */
export async function adjustStock(input: {
  readonly itemId: string;
  readonly branchId: string;
  readonly source: StockSource;
  readonly quantity: number;
  readonly reason: string;
}): Promise<InventoryResult> {
  const context = await requirePermission('inventory.stock.adjust');
  const supabase = await createSupabaseServerClient();

  const reason = input.reason?.trim() ?? '';

  if (!input.itemId) {
    return { ok: false, error: 'Choose the item to adjust.' };
  }
  if (!input.quantity) {
    return { ok: false, error: 'An adjustment of zero changes nothing.' };
  }
  if (!reason) {
    return {
      ok: false,
      error: 'Give a reason. It is recorded on the movement so the change can be explained later.',
    };
  }
  if (!context.accessibleBranches.some((b) => b.id === input.branchId)) {
    return { ok: false, error: 'That is not a branch you can adjust stock at.' };
  }

  const { error } = await supabase.rpc('adjust_inventory_stock', {
    p_item_id: input.itemId,
    p_branch_id: input.branchId,
    p_source: input.source,
    p_quantity: input.quantity,
    p_reason: reason,
  });

  if (error) {
    console.error('[inventory] adjustment failed', error.message);
    return { ok: false, error: describeInventoryError(error.message) };
  }

  await recordAudit({
    action: 'STOCK_ADJUST',
    entityType: 'inventory_stock',
    entityId: input.itemId,
    dealerId: context.dealerId,
    branchId: input.branchId,
    userId: context.userId,
    userEmail: context.email,
    newData: { adjustment: input.quantity, source: input.source },
    reason,
  });

  const direction = input.quantity > 0 ? 'added to' : 'removed from';
  return {
    ok: true,
    message: `${Math.abs(input.quantity)} ${direction} ${input.source.toLowerCase()} stock, with the reason on the ledger entry.`,
  };
}

function describeInventoryError(message: string): string {
  if (message.includes('at the source branch')) {
    return message.replace('Only', 'The source branch holds only');
  }
  if (message.includes('would drive it negative')) {
    return message;
  }
  if (message.includes('requires a reason')) {
    return 'A stock adjustment requires a reason.';
  }
  if (message.includes('Item not found')) {
    return 'That item no longer exists.';
  }
  return `The stock movement could not be recorded: ${message}`;
}

/** The movement types the ledger can hold — spec §34. */
export const MOVEMENT_TYPES = [
  'OPENING', 'PURCHASE', 'SALE', 'CONSUMPTION', 'RETURN',
  'TRANSFER_OUT', 'TRANSFER_IN', 'ADJUSTMENT', 'REVERSAL',
] as const;

export type MovementType = (typeof MOVEMENT_TYPES)[number];

export interface LedgerEntry {
  readonly id: number;
  readonly at: string;
  readonly itemId: string;
  readonly itemCode: string;
  readonly itemName: string;
  readonly branchName: string;
  readonly source: StockSource;
  readonly type: MovementType;
  /** Signed: positive receives, negative issues. */
  readonly quantity: number;
  readonly unitCost: Paise;
  readonly value: Paise;
  /** Lot balance after this movement, as recorded at the time. */
  readonly balanceAfter: number;
  readonly referenceType: string | null;
  readonly referenceNumber: string | null;
  readonly narration: string | null;
  readonly reason: string | null;
}

export interface LedgerTotals {
  readonly received: number;
  readonly issued: number;
  readonly receivedValue: Paise;
  readonly issuedValue: Paise;
}

/**
 * The stock ledger — spec §34.
 *
 * Every movement, in the order it happened, with the balance each one left
 * behind. `balance_after` is read rather than recomputed: it was written under
 * the same row lock that moved the stock, so it is what the balance actually was
 * at that moment. Recomputing it here from a filtered window would produce a
 * number that never existed.
 *
 * Newest first for reading, which means the running balance descends down the
 * page — correct, and the reason the column is labelled as the balance *after*
 * each movement rather than a running total.
 */
export async function getStockLedger(params: {
  readonly branchId: string | null;
  readonly itemId?: string | null;
  readonly type?: string;
  readonly source?: string;
  readonly from: string;
  readonly to: string;
  /**
   * Row cap. Defaults to the screen's, which is all anyone scrolls; the
   * report exporter raises it, because a spreadsheet has no such limit and a
   * silently truncated financial extract is worse than none.
   */
  readonly limit?: number;
}): Promise<{ entries: LedgerEntry[]; totals: LedgerTotals }> {
  const context = await requirePermission('inventory.ledger.view');
  const supabase = await createSupabaseServerClient();

  let query = supabase
    .from('inventory_transactions')
    .select(
      'id, created_at, item_id, branch_id, source, transaction_type, quantity, unit_cost, value, balance_after, reference_type, reference_number, narration, reason, inventory_items!inner ( item_code, name ), branches!inner ( name )',
    )
    .gte('created_at', `${params.from}T00:00:00`)
    // The whole of the closing day, not up to its midnight.
    .lte('created_at', `${params.to}T23:59:59.999`)
    .order('created_at', { ascending: false })
    .order('id', { ascending: false })
    .limit(params.limit ?? 500);

  const branchId = resolveBranch(context, params.branchId);
  if (branchId) {
    query = query.eq('branch_id', branchId);
  }
  if (params.itemId) {
    query = query.eq('item_id', params.itemId);
  }
  if (params.type && params.type !== 'ALL') {
    query = query.eq('transaction_type', params.type as MovementType);
  }
  if (params.source && params.source !== 'ALL') {
    query = query.eq('source', params.source as StockSource);
  }

  const { data, error } = await query;
  if (error) {
    throw new Error(`Failed to load the stock ledger: ${error.message}`);
  }

  const maySeeCost = context.permissions.has('inventory.view_cost');

  const entries: LedgerEntry[] = (data ?? []).map((row) => ({
    id: row.id,
    at: row.created_at,
    itemId: row.item_id,
    itemCode: row.inventory_items.item_code,
    itemName: row.inventory_items.name,
    branchName: row.branches.name,
    source: row.source as StockSource,
    type: row.transaction_type as MovementType,
    quantity: Number(row.quantity),
    unitCost: maySeeCost ? fromDb(row.unit_cost) : (0 as Paise),
    value: maySeeCost ? fromDb(row.value) : (0 as Paise),
    balanceAfter: Number(row.balance_after),
    referenceType: row.reference_type,
    referenceNumber: row.reference_number,
    narration: row.narration,
    reason: row.reason,
  }));

  const totals = entries.reduce<{ received: number; issued: number; receivedValue: number; issuedValue: number }>(
    (acc, entry) => {
      if (entry.quantity > 0) {
        acc.received += entry.quantity;
        acc.receivedValue += entry.value;
      } else {
        acc.issued += -entry.quantity;
        acc.issuedValue += -entry.value;
      }
      return acc;
    },
    { received: 0, issued: 0, receivedValue: 0, issuedValue: 0 },
  );

  return {
    entries,
    totals: {
      received: Number(totals.received.toFixed(3)),
      issued: Number(totals.issued.toFixed(3)),
      receivedValue: totals.receivedValue as Paise,
      issuedValue: totals.issuedValue as Paise,
    },
  };
}

/** Items that have ever moved or are currently held, for the ledger filter. */
export async function getLedgerItemOptions(): Promise<
  readonly { id: string; label: string }[]
> {
  await requirePermission('inventory.ledger.view');
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase
    .from('inventory_items')
    .select('id, item_code, name')
    .eq('status', 'ACTIVE')
    .order('name')
    .limit(1000);

  if (error) {
    throw new Error(`Failed to load items: ${error.message}`);
  }

  return (data ?? []).map((row) => ({ id: row.id, label: `${row.item_code} · ${row.name}` }));
}

// ── Opening stock upload — spec §14, §34 ─────────────────────────────────────

export interface OpeningStockRow {
  readonly rowNumber: number;
  readonly item_code: string;
  readonly branch_code: string;
  readonly source: string;
  readonly quantity: string;
  readonly unit_cost: string;
  readonly errors: readonly string[];
}

export interface OpeningStockPreview {
  readonly rows: readonly OpeningStockRow[];
  readonly validCount: number;
  readonly errorCount: number;
  readonly headers: readonly string[];
}

export interface OpeningStockResult {
  readonly ok: boolean;
  readonly imported?: number;
  readonly error?: string;
}

const OPENING_HEADERS = ['item_code', 'branch_code', 'source', 'quantity', 'unit_cost'] as const;

interface UploadLookup {
  readonly items: Map<string, { id: string; name: string }>;
  readonly branches: Map<string, string>;
  /** Lots that already carry an OPENING row, keyed item|branch|source. */
  readonly opened: Set<string>;
}

async function uploadLookup(context: TenantContext): Promise<UploadLookup> {
  const supabase = await createSupabaseServerClient();

  const [items, existing] = await Promise.all([
    supabase.from('inventory_items').select('id, item_code, name').eq('status', 'ACTIVE').limit(5000),
    supabase
      .from('inventory_transactions')
      .select('item_id, branch_id, source')
      .eq('transaction_type', 'OPENING')
      .limit(20000),
  ]);

  if (items.error) throw new Error(`Failed to load items: ${items.error.message}`);
  if (existing.error) throw new Error(`Failed to load stock history: ${existing.error.message}`);

  return {
    items: new Map(
      (items.data ?? []).map((row) => [row.item_code.toUpperCase(), { id: row.id, name: row.name }]),
    ),
    // Only branches the user may act for; an upload must not reach past them.
    branches: new Map(context.accessibleBranches.map((b) => [b.code.toUpperCase(), b.id])),
    opened: new Set(
      (existing.data ?? []).map((row) => `${row.item_id}|${row.branch_id}|${row.source}`),
    ),
  };
}

/**
 * Validates an opening-stock file and reports what would happen. Writes nothing.
 *
 * Spec §14's order — upload, preview, validate, error report, confirm — exists
 * so an operator sees every problem at once rather than one per attempt.
 */
export async function previewOpeningStock(csv: string): Promise<OpeningStockPreview> {
  const context = await requirePermission('inventory.stock.upload');
  const lookup = await uploadLookup(context);
  const { headers, rows } = parseCsv(csv);

  if (rows.length === 0) {
    return { rows: [], validCount: 0, errorCount: 0, headers: [] };
  }

  const missing = OPENING_HEADERS.filter((h) => !headers.includes(h));
  if (missing.length > 0) {
    return {
      rows: [
        {
          rowNumber: 0,
          item_code: '', branch_code: '', source: '', quantity: '', unit_cost: '',
          errors: [`The file is missing required columns: ${missing.join(', ')}.`],
        },
      ],
      validCount: 0,
      errorCount: 1,
      headers,
    };
  }

  // A lot named twice in one file would be imported twice and double-count, and
  // the ledger afterwards could not say which row was the mistake.
  const seen = new Set<string>();

  const parsed = rows.map((row, index) => {
    const errors: string[] = [];
    const itemCode = (row.item_code ?? '').toUpperCase();
    const branchCode = (row.branch_code ?? '').toUpperCase();
    const source = (row.source ?? '').toUpperCase();
    const quantity = row.quantity ?? '';
    const unitCost = row.unit_cost ?? '';

    const item = lookup.items.get(itemCode);
    const branchId = lookup.branches.get(branchCode);

    if (!itemCode) errors.push('Item code is required.');
    else if (!item) errors.push(`No active item has the code ${itemCode}.`);

    if (!branchCode) errors.push('Branch code is required.');
    else if (!branchId) errors.push(`${branchCode} is not a branch you can upload stock for.`);

    if (source !== 'LOCAL' && source !== 'COMPANY') {
      errors.push('Source must be LOCAL or COMPANY (spec §28 keeps the two apart).');
    }

    const qty = Number(quantity.replace(/,/g, ''));
    if (!quantity) errors.push('Quantity is required.');
    else if (!Number.isFinite(qty) || qty <= 0) errors.push('Quantity must be a number greater than zero.');

    const cost = Number(unitCost.replace(/,/g, ''));
    if (!unitCost) errors.push('Unit cost is required.');
    else if (!Number.isFinite(cost) || cost < 0) errors.push('Unit cost must be zero or more.');

    if (item && branchId && (source === 'LOCAL' || source === 'COMPANY')) {
      const key = `${item.id}|${branchId}|${source}`;
      if (seen.has(key)) {
        errors.push('This item, branch and source appears more than once in the file.');
      }
      seen.add(key);

      // Opening stock entered twice is a silent double-count that the ledger
      // cannot distinguish from a genuine second receipt.
      if (lookup.opened.has(key)) {
        errors.push(`${item.name} already has opening stock at ${branchCode} in ${source}.`);
      }
    }

    return {
      rowNumber: index + 1,
      item_code: itemCode,
      branch_code: branchCode,
      source,
      quantity,
      unit_cost: unitCost,
      errors,
    };
  });

  return {
    rows: parsed,
    validCount: parsed.filter((r) => r.errors.length === 0).length,
    errorCount: parsed.filter((r) => r.errors.length > 0).length,
    headers,
  };
}

/**
 * Imports the file, or nothing at all — spec §14.
 *
 * The preview is re-run server-side rather than trusted from the client, and a
 * single multi-row insert makes the write all-or-nothing. Each row becomes an
 * OPENING movement; `inventory_stock` and `balance_after` follow by trigger, so
 * quantity is never written directly (spec §34).
 */
export async function commitOpeningStock(csv: string): Promise<OpeningStockResult> {
  const context = await requirePermission('inventory.stock.upload');
  if (!context.dealerId) {
    return { ok: false, error: 'No dealer is in context.' };
  }

  const preview = await previewOpeningStock(csv);

  if (preview.rows.length === 0) {
    return { ok: false, error: 'The file contains no rows.' };
  }
  if (preview.errorCount > 0) {
    return {
      ok: false,
      error: `${preview.errorCount} row(s) still have errors. Fix them and upload again — nothing has been imported.`,
    };
  }

  const lookup = await uploadLookup(context);
  const supabase = await createSupabaseServerClient();

  const payload = preview.rows.map((row) => ({
    dealer_id: context.dealerId!,
    branch_id: lookup.branches.get(row.branch_code)!,
    item_id: lookup.items.get(row.item_code)!.id,
    source: row.source,
    transaction_type: 'OPENING',
    quantity: Number(row.quantity.replace(/,/g, '')),
    unit_cost: Number(row.unit_cost.replace(/,/g, '')),
    reference_type: 'OPENING',
    narration: 'Opening stock import',
    created_by: context.userId,
  }));

  const { error } = await supabase.from('inventory_transactions').insert(payload as never);

  if (error) {
    console.error('[inventory] opening stock import failed', error.message);
    return { ok: false, error: `Nothing was imported: ${describeInventoryError(error.message)}` };
  }

  await recordAudit({
    action: 'IMPORT',
    entityType: 'inventory_transactions',
    dealerId: context.dealerId,
    branchId: context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
    newData: { imported: payload.length, items: preview.rows.slice(0, 50).map((r) => r.item_code) },
  });

  return { ok: true, imported: payload.length };
}
