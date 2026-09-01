import 'server-only';

import { requirePermission, type TenantContext } from '@/server/auth/tenant-context';
import { scrubRestrictedFields } from '@/lib/permissions';
import { fromRupees } from '@/lib/money';
import * as repository from '@/server/repositories/vehicle-repository';
import { recordAudit } from '@/server/services/audit/record-audit';

export type { Vehicle, VehicleListRow, VehicleDetail, StockSummary } from '@/server/repositories/vehicle-repository';
export { VEHICLES_PAGE_SIZE } from '@/server/repositories/vehicle-repository';

/**
 * Vehicle stock — spec §13, §14, §60.8.
 *
 * The import in this file is the part worth reading. Spec §14 is explicit:
 * validate before importing, produce an error report, and "do not partially
 * import silently". So parsing and validation are a separate step from the
 * commit, and the commit is all-or-nothing.
 */

function resolveBranch(context: TenantContext, requested: string | null): string | null {
  if (!requested) {
    return context.hasAllBranchAccess ? null : (context.activeBranch?.id ?? null);
  }
  const allowed = context.accessibleBranches.some((b) => b.id === requested);
  return allowed ? requested : (context.activeBranch?.id ?? null);
}

export async function getVehicles(params: {
  readonly q?: string;
  readonly status: string;
  readonly branchId: string | null;
  readonly modelId: string | null;
  readonly page: number;
}) {
  const context = await requirePermission('vehicles.stock.view');
  const result = await repository.listVehicles({
    ...params,
    branchId: resolveBranch(context, params.branchId),
  });

  // Purchase cost is restricted (spec §52). Strip it here rather than hiding it
  // in the table, so it never reaches the browser for a role without the
  // permission.
  if (!context.permissions.has('vehicles.view_cost')) {
    return {
      ...result,
      rows: result.rows.map(({ purchase_cost: _cost, ...rest }) => ({ ...rest, purchase_cost: 0 as never })),
    };
  }
  return result;
}

export async function getVehicle(id: string) {
  const context = await requirePermission('vehicles.stock.view');
  const detail = await repository.getVehicle(id);
  if (!detail) {
    return null;
  }
  if (!context.permissions.has('vehicles.view_cost')) {
    return scrubRestrictedFields(
      { ...detail, vehicle: { ...detail.vehicle, purchase_cost: '0' } },
      context.permissions,
    );
  }
  return detail;
}

export async function getStockSummary(branchId: string | null) {
  const context = await requirePermission('vehicles.stock.view');
  return repository.getStockSummary(resolveBranch(context, branchId));
}

export async function getCatalogueLookup() {
  await requirePermission('vehicles.stock.view');
  return repository.getCatalogueLookup();
}

// ─────────────────────────────────────────────────────────────────────────────
// CSV / Excel import — spec §14
// ─────────────────────────────────────────────────────────────────────────────

export interface ImportRow {
  readonly rowNumber: number;
  readonly chassis_no: string;
  readonly engine_no: string;
  readonly model_code: string;
  readonly variant_code: string;
  readonly branch_code: string;
  readonly colour: string;
  readonly key_no: string;
  readonly purchase_invoice: string;
  readonly purchase_date: string;
  readonly purchase_cost: string;
  readonly errors: readonly string[];
}

export interface ImportPreview {
  readonly rows: readonly ImportRow[];
  readonly validCount: number;
  readonly errorCount: number;
  readonly headers: readonly string[];
}

const REQUIRED_HEADERS = [
  'chassis_no',
  'engine_no',
  'model_code',
  'branch_code',
  'purchase_invoice',
  'purchase_cost',
] as const;

/**
 * Parses and validates an upload without writing anything.
 *
 * Every check spec §14 lists is applied here: duplicate chassis, duplicate
 * engine, unknown model, unknown variant, unknown branch, missing cost, missing
 * invoice. Duplicates are checked both against the database and within the file
 * itself, because a spreadsheet that repeats a chassis is the common case.
 */
export async function previewImport(csv: string): Promise<ImportPreview> {
  await requirePermission('vehicles.stock.upload');

  const [existing, catalogue] = await Promise.all([
    repository.getExistingIdentifiers(),
    repository.getCatalogueLookup(),
  ]);

  const lines = csv.split(/\r?\n/).filter((line) => line.trim().length > 0);
  if (lines.length === 0) {
    return { rows: [], validCount: 0, errorCount: 0, headers: [] };
  }

  const headers = splitCsvLine(lines[0]!).map((h) => h.trim().toLowerCase().replace(/\s+/g, '_'));

  const missingHeaders = REQUIRED_HEADERS.filter((h) => !headers.includes(h));
  if (missingHeaders.length > 0) {
    return {
      rows: [
        {
          rowNumber: 0,
          chassis_no: '', engine_no: '', model_code: '', variant_code: '', branch_code: '',
          colour: '', key_no: '', purchase_invoice: '', purchase_date: '', purchase_cost: '',
          errors: [`The file is missing required columns: ${missingHeaders.join(', ')}.`],
        },
      ],
      validCount: 0,
      errorCount: 1,
      headers,
    };
  }

  // Duplicates within the file itself, not just against the database.
  const seenChassis = new Set<string>();
  const seenEngine = new Set<string>();
  const rows: ImportRow[] = [];

  for (let i = 1; i < lines.length; i += 1) {
    const cells = splitCsvLine(lines[i]!);
    const get = (name: string) => (cells[headers.indexOf(name)] ?? '').trim();

    const chassis = get('chassis_no').toUpperCase();
    const engine = get('engine_no').toUpperCase();
    const modelCode = get('model_code').toUpperCase();
    const variantCode = get('variant_code').toUpperCase();
    const branchCode = get('branch_code').toUpperCase();
    const cost = get('purchase_cost');
    const invoice = get('purchase_invoice');
    const purchaseDate = get('purchase_date');

    const errors: string[] = [];

    if (!chassis) errors.push('Chassis number is required.');
    else if (!/^[A-Z0-9]{6,25}$/.test(chassis)) errors.push('Chassis number must be 6–25 letters or digits.');
    else if (existing.chassis.has(chassis)) errors.push('This chassis is already in stock.');
    else if (seenChassis.has(chassis)) errors.push('This chassis appears more than once in the file.');

    if (!engine) errors.push('Engine number is required.');
    else if (!/^[A-Z0-9]{6,25}$/.test(engine)) errors.push('Engine number must be 6–25 letters or digits.');
    else if (existing.engine.has(engine)) errors.push('This engine number is already in stock.');
    else if (seenEngine.has(engine)) errors.push('This engine number appears more than once in the file.');

    if (!modelCode) errors.push('Model code is required.');
    else if (!catalogue.models.has(modelCode)) errors.push(`Unknown model code "${modelCode}".`);

    if (variantCode) {
      const variant = catalogue.variants.get(variantCode);
      if (!variant) errors.push(`Unknown variant code "${variantCode}".`);
      else if (catalogue.models.get(modelCode) && variant.modelId !== catalogue.models.get(modelCode)!.id) {
        errors.push(`Variant "${variantCode}" does not belong to model "${modelCode}".`);
      }
    }

    if (!branchCode) errors.push('Branch code is required.');
    else if (!catalogue.branches.has(branchCode)) errors.push(`Unknown branch code "${branchCode}".`);

    if (!invoice) errors.push('Purchase invoice is required.');

    if (!cost) errors.push('Purchase cost is required.');
    else if (!/^\d+(\.\d{1,4})?$/.test(cost.replace(/,/g, ''))) errors.push('Purchase cost is not a valid amount.');
    else if (Number(cost.replace(/,/g, '')) <= 0) errors.push('Purchase cost must be greater than zero.');

    if (purchaseDate && !/^\d{4}-\d{2}-\d{2}$/.test(purchaseDate)) {
      errors.push('Purchase date must be in YYYY-MM-DD format.');
    }

    if (chassis) seenChassis.add(chassis);
    if (engine) seenEngine.add(engine);

    rows.push({
      rowNumber: i + 1,
      chassis_no: chassis,
      engine_no: engine,
      model_code: modelCode,
      variant_code: variantCode,
      branch_code: branchCode,
      colour: get('colour'),
      key_no: get('key_no'),
      purchase_invoice: invoice,
      purchase_date: purchaseDate,
      purchase_cost: cost,
      errors,
    });
  }

  return {
    rows,
    validCount: rows.filter((r) => r.errors.length === 0).length,
    errorCount: rows.filter((r) => r.errors.length > 0).length,
    headers,
  };
}

export interface ImportResult {
  readonly ok: boolean;
  readonly imported?: number;
  readonly error?: string;
}

/**
 * Commits a previously validated file.
 *
 * Refuses outright if any row has an error. Spec §14: "Do not partially import
 * silently" — importing the good rows and reporting the rest would leave the
 * operator with a half-loaded stock list and no clear way to tell what landed.
 */
export async function commitImport(csv: string): Promise<ImportResult> {
  const context = await requirePermission('vehicles.stock.upload');

  if (!context.dealerId) {
    return { ok: false, error: 'Your account is not attached to a dealer.' };
  }

  const preview = await previewImport(csv);

  if (preview.rows.length === 0) {
    return { ok: false, error: 'The file contains no rows.' };
  }
  if (preview.errorCount > 0) {
    return {
      ok: false,
      error: `${preview.errorCount} row(s) still have errors. Fix them and upload again — nothing has been imported.`,
    };
  }

  const catalogue = await repository.getCatalogueLookup();

  const payload = preview.rows.map((row) => ({
    branch_id: catalogue.branches.get(row.branch_code)!,
    model_id: catalogue.models.get(row.model_code)!.id,
    variant_id: row.variant_code ? (catalogue.variants.get(row.variant_code)?.id ?? null) : null,
    chassis_no: row.chassis_no,
    engine_no: row.engine_no,
    key_no: row.key_no || null,
    purchase_invoice: row.purchase_invoice,
    purchase_date: row.purchase_date || null,
    // Round-trip through paise so the stored value cannot drift by a float.
    purchase_cost: (fromRupees(Number(row.purchase_cost.replace(/,/g, ''))) / 100).toFixed(4),
    stock_date: row.purchase_date || new Date().toISOString().slice(0, 10),
  }));

  try {
    // One INSERT: PostgREST wraps a multi-row insert in a single statement, so
    // either every vehicle lands or none does.
    const imported = await repository.insertVehicles(payload, {
      dealerId: context.dealerId,
      userId: context.userId,
    });

    await recordAudit({
      action: 'IMPORT',
      entityType: 'vehicles',
      dealerId: context.dealerId,
      branchId: context.activeBranch?.id ?? null,
      userId: context.userId,
      userEmail: context.email,
      newData: { imported, chassis: payload.map((p) => p.chassis_no).slice(0, 50) },
    });

    return { ok: true, imported };
  } catch (error) {
    const code = (error as { code?: string })?.code;
    const message = (error as { message?: string })?.message ?? String(error);
    console.error('[vehicles] import failed', { code, message });

    if (code === '23505') {
      return {
        ok: false,
        error: 'A chassis or engine number in the file is already in stock. Nothing was imported.',
      };
    }
    return { ok: false, error: 'The import failed. Nothing was imported.' };
  }
}

/**
 * Splits one CSV line, honouring quoted fields.
 *
 * A naive `split(',')` breaks on any address or description containing a comma,
 * which real dealer exports invariably do.
 */
function splitCsvLine(line: string): string[] {
  const cells: string[] = [];
  let current = '';
  let inQuotes = false;

  for (let i = 0; i < line.length; i += 1) {
    const char = line[i];
    if (char === '"') {
      // A doubled quote inside a quoted field is a literal quote.
      if (inQuotes && line[i + 1] === '"') {
        current += '"';
        i += 1;
      } else {
        inQuotes = !inQuotes;
      }
    } else if (char === ',' && !inQuotes) {
      cells.push(current);
      current = '';
    } else {
      current += char;
    }
  }
  cells.push(current);
  return cells;
}
