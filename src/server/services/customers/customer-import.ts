import 'server-only';

import { requirePermission } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { recordAudit } from '@/server/services/audit/record-audit';
import { customerSchema } from '@/lib/validation/customer';
import { parseCsv } from '@/lib/csv';

/**
 * Customer bulk import — spec §11, §14.
 *
 * A dealer arriving with an existing business arrives with their customers, and
 * until now there was no way in but the one-at-a-time form. Vehicles and opening
 * stock have had an importer since Phase 3; this is the same shape for the
 * master that carries the most rows.
 *
 * The flow spec §14 prescribes, unchanged:
 *
 *     Upload → Preview → Validation → Error report → Confirm → Audit
 *
 * Nothing is written until Confirm, and Confirm refuses while any row has an
 * error. §14 is explicit that a partial import must not happen silently: landing
 * the good rows and listing the rest leaves the operator unable to say what is
 * in the database without checking it row by row.
 *
 * ── Validation is not restated here ─────────────────────────────────────────
 *
 * Every rule comes from `customerSchema`, the same schema the single-customer
 * form uses and a mirror of the table's own constraints. Writing a second set
 * for the importer is how a file that previews clean gets rejected by the
 * database — the two drift, and the drift only shows up at commit.
 *
 * ── Existing customer codes are kept ────────────────────────────────────────
 *
 * `customer_code` is optional in the file and honoured when present. The trigger
 * in 0013 was written for exactly this — "an explicit code (data migration) is
 * respected" — and it matters more than it looks: a dealer's paper records, old
 * invoices and their customers' own memories all use the codes they already
 * have. Renumbering them at cut-over makes every historical document unfindable
 * by the number printed on it.
 */

export interface CustomerImportRow {
  readonly rowNumber: number;
  readonly customer_code: string;
  readonly name: string;
  readonly customer_type: string;
  readonly mobile: string;
  readonly alternate_mobile: string;
  readonly email: string;
  readonly address_line1: string;
  readonly city: string;
  readonly state: string;
  readonly state_code: string;
  readonly pincode: string;
  readonly gstin: string;
  readonly pan: string;
  readonly errors: readonly string[];
}

export interface CustomerImportPreview {
  readonly rows: readonly CustomerImportRow[];
  readonly validCount: number;
  readonly errorCount: number;
  readonly headers: readonly string[];
}

export interface CustomerImportResult {
  readonly ok: boolean;
  readonly imported?: number;
  readonly error?: string;
}

/** Only these two are required; everything else is optional detail. */
const REQUIRED_HEADERS = ['name', 'mobile'] as const;

/** The columns the importer reads. Anything else in the file is ignored. */
const KNOWN_HEADERS = [
  'customer_code', 'name', 'customer_type', 'mobile', 'alternate_mobile', 'email',
  'address_line1', 'address_line2', 'city', 'state', 'state_code', 'pincode',
  'gstin', 'pan', 'notes',
] as const;

const EMPTY_ROW = {
  rowNumber: 0,
  customer_code: '', name: '', customer_type: '', mobile: '', alternate_mobile: '',
  email: '', address_line1: '', city: '', state: '', state_code: '', pincode: '',
  gstin: '', pan: '',
};

/** A preview carrying one file-level complaint rather than a row-level one. */
function fileError(message: string, headers: string[] = []): CustomerImportPreview {
  return {
    rows: [{ ...EMPTY_ROW, errors: [message] }],
    validCount: 0,
    errorCount: 1,
    headers,
  };
}

/**
 * Parses and validates an upload without writing anything.
 *
 * Duplicates are checked twice over: against the database, and within the file
 * itself. The second is not redundant — a spreadsheet assembled from several
 * branches repeating a customer is the ordinary case, and without the in-file
 * check the whole insert would fail at the unique index with nothing to say
 * which row caused it.
 */
export async function previewCustomerImport(csv: string): Promise<CustomerImportPreview> {
  const context = await requirePermission('customers.import');
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

  // Existing mobiles and codes, so the file can be checked against what is
  // already there. Scoped by RLS to this dealer.
  const [{ data: existing, error }] = await Promise.all([
    supabase.from('customers').select('mobile, customer_code, gstin'),
  ]);

  if (error) {
    throw new Error(`Failed to read existing customers: ${error.message}`);
  }

  const haveMobile = new Set((existing ?? []).map((c) => c.mobile));
  const haveCode = new Set((existing ?? []).map((c) => c.customer_code));
  const haveGstin = new Set((existing ?? []).filter((c) => c.gstin).map((c) => c.gstin as string));

  const seenMobile = new Map<string, number>();
  const seenCode = new Map<string, number>();
  const seenGstin = new Map<string, number>();

  const rows: CustomerImportRow[] = raw.map((cells, index) => {
    const rowNumber = index + 2; // +1 for the header, +1 because people count from 1
    const get = (name: string) => (cells[name] ?? '').trim();

    const candidate = {
      name: get('name'),
      customer_type: get('customer_type').toUpperCase() || 'INDIVIDUAL',
      mobile: get('mobile'),
      alternate_mobile: get('alternate_mobile'),
      email: get('email'),
      address_line1: get('address_line1'),
      address_line2: get('address_line2'),
      city: get('city'),
      state: get('state'),
      state_code: get('state_code'),
      pincode: get('pincode'),
      gstin: get('gstin'),
      pan: get('pan'),
      notes: get('notes'),
    };

    const errors: string[] = [];

    // Every rule, from the one schema that already holds them.
    const parsed = customerSchema.safeParse(candidate);
    if (!parsed.success) {
      for (const issue of parsed.error.issues) {
        const field = issue.path.join('.') || 'row';
        errors.push(`${field}: ${issue.message}`);
      }
    }

    const code = get('customer_code');
    const mobile = candidate.mobile;
    const gstin = candidate.gstin.toUpperCase();

    if (mobile) {
      if (haveMobile.has(mobile)) {
        errors.push(`mobile: ${mobile} already belongs to a customer on file.`);
      }
      const first = seenMobile.get(mobile);
      if (first) errors.push(`mobile: repeated in this file (also row ${first}).`);
      else seenMobile.set(mobile, rowNumber);
    }

    if (code) {
      if (haveCode.has(code)) {
        errors.push(`customer_code: ${code} is already used by another customer.`);
      }
      const first = seenCode.get(code);
      if (first) errors.push(`customer_code: repeated in this file (also row ${first}).`);
      else seenCode.set(code, rowNumber);
    }

    // A repeated GSTIN is not always wrong — one business can have several
    // contacts — so it is worth flagging and not worth refusing over. But the
    // same GSTIN twice in one migration file is almost always the same company
    // entered twice, which is exactly what a preview is for.
    if (gstin) {
      if (haveGstin.has(gstin)) {
        errors.push(`gstin: ${gstin} is already on another customer.`);
      }
      const first = seenGstin.get(gstin);
      if (first) errors.push(`gstin: repeated in this file (also row ${first}).`);
      else seenGstin.set(gstin, rowNumber);
    }

    return {
      rowNumber,
      customer_code: code,
      name: candidate.name,
      customer_type: candidate.customer_type,
      mobile,
      alternate_mobile: candidate.alternate_mobile,
      email: candidate.email,
      address_line1: candidate.address_line1,
      city: candidate.city,
      state: candidate.state,
      state_code: candidate.state_code,
      pincode: candidate.pincode,
      gstin,
      pan: candidate.pan.toUpperCase(),
      errors,
    };
  });

  const errorCount = rows.filter((r) => r.errors.length > 0).length;

  void context;
  return { rows, validCount: rows.length - errorCount, errorCount, headers };
}

/**
 * Writes the file, or none of it.
 *
 * Re-previews rather than trusting a preview the client hands back: the browser
 * could send a different file from the one it showed, and the check that matters
 * is the one made against the database at the moment of writing.
 */
export async function commitCustomerImport(csv: string): Promise<CustomerImportResult> {
  const context = await requirePermission('customers.import');

  if (!context.dealerId) {
    return { ok: false, error: 'Your account is not attached to a dealer.' };
  }

  const preview = await previewCustomerImport(csv);

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
    // Omitted, not nulled, when the file does not carry one: the column is NOT
    // NULL and the trigger in 0013 fills it. Sending an explicit null would be
    // rejected before the trigger ever saw the row.
    ...(row.customer_code ? { customer_code: row.customer_code } : {}),
    name: row.name,
    // Narrowed rather than cast: the schema has already rejected anything else,
    // so this is restating what validation proved, not asserting past it.
    customer_type: row.customer_type === 'BUSINESS' ? ('BUSINESS' as const) : ('INDIVIDUAL' as const),
    mobile: row.mobile,
    alternate_mobile: row.alternate_mobile || null,
    email: row.email || null,
    address_line1: row.address_line1 || null,
    city: row.city || null,
    state: row.state || null,
    state_code: row.state_code || null,
    pincode: row.pincode || null,
    gstin: row.gstin || null,
    pan: row.pan || null,
    origin_branch_id: context.activeBranch?.id ?? null,
    created_by: context.userId,
  }));

  // One INSERT. PostgREST sends a multi-row insert as a single statement, so
  // either every customer lands or none does — which is what §14 means by not
  // importing partially.
  const { data, error } = await supabase.from('customers').insert(payload).select('id');

  if (error) {
    console.error('[customers] import failed', error.code, error.message);
    if (error.code === '23505') {
      return {
        ok: false,
        error:
          'A mobile number or customer code in the file is already taken. ' +
          'Nothing was imported — re-upload to see which row.',
      };
    }
    if (error.code === '23514') {
      return {
        ok: false,
        error: `A row was rejected by the database: ${error.message}. Nothing was imported.`,
      };
    }
    return { ok: false, error: 'The import failed. Nothing was imported.' };
  }

  const imported = data?.length ?? 0;

  await recordAudit({
    action: 'IMPORT',
    entityType: 'customers',
    dealerId: context.dealerId,
    branchId: context.activeBranch?.id ?? null,
    userId: context.userId,
    userEmail: context.email,
    newData: {
      imported,
      // Enough to identify what went in without copying the whole file into the
      // audit row.
      mobiles: payload.map((p) => p.mobile).slice(0, 50),
    },
  });

  return { ok: true, imported };
}

/** The header row, so the operator starts from something that works. */
export function customerImportTemplate(): string {
  return (
    KNOWN_HEADERS.join(',') +
    '\n' +
    'CUST-000001,Ramesh Kumar,INDIVIDUAL,9876543210,,ramesh@example.com,' +
    '12 Gandhi Street,,Coimbatore,Tamil Nadu,33,641001,,ABCDE1234F,Migrated from old system\n'
  );
}
