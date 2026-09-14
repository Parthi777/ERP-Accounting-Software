import 'server-only';

import { requirePermission } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { recordAudit } from '@/server/services/audit/record-audit';
import { supplierSchema } from '@/lib/validation/masters';
import { parseCsv } from '@/lib/csv';

/**
 * Supplier bulk import — spec §14, §44.
 *
 * The same shape as the customer importer and for the same reason: a dealer
 * cutting over brings the people they buy from as well as the people they sell
 * to, and the payable ledger is meaningless until they are in.
 *
 * Fewer rows than customers, and the rules differ in one way worth knowing:
 * a supplier's mobile is optional. Some are OEM accounts with nothing but a
 * name and a GSTIN, so `mobile` cannot be the duplicate key the way it is for
 * customers — `supplier_code` and `gstin` do that work here.
 */

export interface SupplierImportRow {
  readonly rowNumber: number;
  readonly supplier_code: string;
  readonly name: string;
  readonly supplier_type: string;
  readonly contact_person: string;
  readonly mobile: string;
  readonly email: string;
  readonly city: string;
  readonly state: string;
  readonly gstin: string;
  readonly credit_days: string;
  readonly errors: readonly string[];
}

export interface SupplierImportPreview {
  readonly rows: readonly SupplierImportRow[];
  readonly validCount: number;
  readonly errorCount: number;
  readonly headers: readonly string[];
}

export interface SupplierImportResult {
  readonly ok: boolean;
  readonly imported?: number;
  readonly error?: string;
}

const REQUIRED_HEADERS = ['name'] as const;

const KNOWN_HEADERS = [
  'supplier_code', 'name', 'supplier_type', 'contact_person', 'mobile', 'email',
  'address_line1', 'city', 'state', 'state_code', 'pincode', 'gstin', 'pan',
  'credit_days', 'notes',
] as const;

const EMPTY_ROW = {
  rowNumber: 0,
  supplier_code: '', name: '', supplier_type: '', contact_person: '', mobile: '',
  email: '', city: '', state: '', gstin: '', credit_days: '',
};

function fileError(message: string, headers: string[] = []): SupplierImportPreview {
  return { rows: [{ ...EMPTY_ROW, errors: [message] }], validCount: 0, errorCount: 1, headers };
}

export async function previewSupplierImport(csv: string): Promise<SupplierImportPreview> {
  await requirePermission('masters.suppliers.manage');
  const supabase = await createSupabaseServerClient();

  const { headers, rows: raw } = parseCsv(csv);

  if (raw.length === 0) {
    return fileError('The file has a header row but no data rows.', headers);
  }

  const missing = REQUIRED_HEADERS.filter((h) => !headers.includes(h));
  if (missing.length > 0) {
    return fileError(
      `The file is missing required columns: ${missing.join(', ')}. ` +
        `Recognised columns are: ${KNOWN_HEADERS.join(', ')}.`,
      headers,
    );
  }

  const { data: existing, error } = await supabase
    .from('suppliers')
    .select('supplier_code, gstin, name');

  if (error) {
    throw new Error(`Failed to read existing suppliers: ${error.message}`);
  }

  const haveCode = new Set((existing ?? []).map((s) => s.supplier_code));
  const haveGstin = new Set((existing ?? []).filter((s) => s.gstin).map((s) => s.gstin as string));
  const haveName = new Set((existing ?? []).map((s) => s.name.trim().toLowerCase()));

  const seenCode = new Map<string, number>();
  const seenGstin = new Map<string, number>();
  const seenName = new Map<string, number>();

  const rows: SupplierImportRow[] = raw.map((cells, index) => {
    const rowNumber = index + 2;
    const get = (name: string) => (cells[name] ?? '').trim();

    const candidate = {
      name: get('name'),
      supplier_type: get('supplier_type').toUpperCase() || 'GOODS',
      contact_person: get('contact_person'),
      mobile: get('mobile'),
      email: get('email'),
      gstin: get('gstin'),
      city: get('city'),
      state: get('state'),
      credit_days: get('credit_days') || '0',
      status: 'ACTIVE' as const,
    };

    const errors: string[] = [];

    const parsed = supplierSchema.safeParse(candidate);
    if (!parsed.success) {
      for (const issue of parsed.error.issues) {
        errors.push(`${issue.path.join('.') || 'row'}: ${issue.message}`);
      }
    }

    const code = get('supplier_code');
    const gstin = candidate.gstin.toUpperCase();
    const nameKey = candidate.name.trim().toLowerCase();

    if (code) {
      if (haveCode.has(code)) errors.push(`supplier_code: ${code} is already in use.`);
      const first = seenCode.get(code);
      if (first) errors.push(`supplier_code: repeated in this file (also row ${first}).`);
      else seenCode.set(code, rowNumber);
    }

    // A GSTIN identifies a legal entity, so the same one twice is the same
    // supplier twice — the nearest thing to a reliable key a supplier has.
    if (gstin) {
      if (haveGstin.has(gstin)) errors.push(`gstin: ${gstin} is already on another supplier.`);
      const first = seenGstin.get(gstin);
      if (first) errors.push(`gstin: repeated in this file (also row ${first}).`);
      else seenGstin.set(gstin, rowNumber);
    }

    // Name matching is a warning in spirit but an error in effect, because a
    // duplicated supplier splits a payable across two ledgers and the split is
    // only noticed when someone chases a balance that looks too small.
    if (nameKey) {
      if (haveName.has(nameKey)) {
        errors.push(`name: a supplier called "${candidate.name}" already exists.`);
      }
      const first = seenName.get(nameKey);
      if (first) errors.push(`name: repeated in this file (also row ${first}).`);
      else seenName.set(nameKey, rowNumber);
    }

    return {
      rowNumber,
      supplier_code: code,
      name: candidate.name,
      supplier_type: candidate.supplier_type,
      contact_person: candidate.contact_person,
      mobile: candidate.mobile,
      email: candidate.email,
      city: candidate.city,
      state: candidate.state,
      gstin,
      credit_days: candidate.credit_days,
      errors,
    };
  });

  const errorCount = rows.filter((r) => r.errors.length > 0).length;
  return { rows, validCount: rows.length - errorCount, errorCount, headers };
}

export async function commitSupplierImport(csv: string): Promise<SupplierImportResult> {
  const context = await requirePermission('masters.suppliers.manage');

  if (!context.dealerId) {
    return { ok: false, error: 'Your account is not attached to a dealer.' };
  }

  const preview = await previewSupplierImport(csv);

  if (preview.rows.length === 0) {
    return { ok: false, error: 'The file contains no rows.' };
  }
  if (preview.errorCount > 0) {
    return {
      ok: false,
      error:
        `${preview.errorCount} row(s) still have errors. Fix them and upload again — ` +
        `nothing has been imported.`,
    };
  }

  const supabase = await createSupabaseServerClient();
  const dealerId = context.dealerId;

  const payload = preview.rows.map((row) => ({
    dealer_id: dealerId,
    // Omitted rather than nulled: the column is NOT NULL and the trigger in
    // 0040 issues one, exactly as customers do.
    ...(row.supplier_code ? { supplier_code: row.supplier_code } : {}),
    name: row.name,
    supplier_type:
      row.supplier_type === 'SERVICE' ? ('SERVICE' as const)
      : row.supplier_type === 'OEM' ? ('OEM' as const)
      : ('GOODS' as const),
    contact_person: row.contact_person || null,
    mobile: row.mobile || null,
    email: row.email || null,
    city: row.city || null,
    state: row.state || null,
    gstin: row.gstin || null,
    credit_days: Number(row.credit_days) || 0,
    created_by: context.userId,
  }));

  const { data, error } = await supabase.from('suppliers').insert(payload).select('id');

  if (error) {
    console.error('[suppliers] import failed', error.code, error.message);
    if (error.code === '23505') {
      return {
        ok: false,
        error:
          'A supplier code in the file is already taken. Nothing was imported — ' +
          're-upload to see which row.',
      };
    }
    return { ok: false, error: `The import failed: ${error.message}. Nothing was imported.` };
  }

  const imported = data?.length ?? 0;

  await recordAudit({
    action: 'IMPORT',
    entityType: 'suppliers',
    dealerId: context.dealerId,
    branchId: context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
    newData: { imported, names: payload.map((p) => p.name).slice(0, 50) },
  });

  return { ok: true, imported };
}

export function supplierImportTemplate(): string {
  return (
    KNOWN_HEADERS.join(',') +
    '\n' +
    'SUPP-000001,Anand Auto Parts,GOODS,Anand Kumar,9876543210,anand@example.com,' +
    '5 Market Road,Coimbatore,Tamil Nadu,33,641001,33ABCDE1234F1Z5,ABCDE1234F,30,' +
    'Migrated from old system\n'
  );
}
