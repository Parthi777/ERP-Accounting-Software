/**
 * Generates src/types/database.types.ts from the live schema.
 *
 * Hand-maintaining 55 table definitions is a losing game: they drift from the
 * migrations silently, and the failure mode is a query that type-checks and then
 * returns nothing. This introspects the database instead, so the types are a
 * consequence of the schema rather than a parallel description of it.
 *
 * Runs against the throwaway verification database by default, which is the same
 * schema the migrations produce. Once your Supabase project is caught up,
 * `supabase gen types typescript` is the equivalent official tool.
 *
 *   node scripts/generate-types.mjs                 # uses twerp_typegen
 *   DB=twerp_migration_check node scripts/generate-types.mjs
 */

import { execFileSync } from 'node:child_process';
import { writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const DB = process.env.DB ?? 'twerp_typegen';
const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const OUT = join(ROOT, 'src', 'types', 'database.types.ts');

function psql(sql) {
  return execFileSync('psql', ['--no-psqlrc', '-q', '-t', '-A', '-F', '', '-d', DB, '-c', sql], {
    encoding: 'utf8',
    maxBuffer: 32 * 1024 * 1024,
  })
    .trim()
    .split('\n')
    .filter(Boolean)
    .map((line) => line.split(''));
}

// ── Type mapping ─────────────────────────────────────────────────────────────
// `numeric` becomes string deliberately: PostgREST serialises it as a string
// because a JS number cannot hold it exactly, and money must stay exact.
function tsType(dataType, udt) {
  if (dataType === 'ARRAY') {
    return udt === '_text' ? 'string[]' : udt === '_uuid' ? 'string[]' : 'unknown[]';
  }
  switch (dataType) {
    case 'boolean':
      return 'boolean';
    case 'smallint':
    case 'integer':
    case 'bigint':
    case 'real':
    case 'double precision':
      return 'number';
    case 'json':
    case 'jsonb':
      return 'Json';
    case 'numeric':
    case 'text':
    case 'character varying':
    case 'character':
    case 'uuid':
    case 'date':
    case 'timestamp with time zone':
    case 'timestamp without time zone':
    case 'time without time zone':
    case 'inet':
      return 'string';
    default:
      return 'string';
  }
}

// A single-column `IN (...)` check becomes a string union, which is what makes
// `.eq('status', 'ACTV')` a compile error instead of an empty result set.
function unionsFor(checks) {
  const map = new Map();
  for (const [, def] of checks) {
    // Postgres normalises `in (...)` to `= ANY (ARRAY[...])`, and renders the
    // column with or without a ::text cast depending on its declared type.
    const match = /\(\(?(\w+)\)?(?:::text)? = ANY \(\(?ARRAY\[(.+?)\]/.exec(def);
    if (!match) continue;
    const column = match[1];
    const values = [...match[2].matchAll(/'([^']+)'::(?:text|character varying)/g)].map((m) => m[1]);
    if (values.length > 0 && values.length <= 24) {
      map.set(column, values.map((v) => `'${v}'`).join(' | '));
    }
  }
  return map;
}

const tables = psql(`
  select c.relname
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r'
   order by c.relname
`).map((r) => r[0]);

const columns = psql(`
  select table_name, column_name, data_type, udt_name, is_nullable,
         coalesce(column_default, ''), is_generated, is_identity
    from information_schema.columns
   where table_schema = 'public'
   order by table_name, ordinal_position
`);

const checks = psql(`
  select t.relname, pg_get_constraintdef(c.oid)
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
   where n.nspname = 'public' and c.contype = 'c'
`);

const fks = psql(`
  select t.relname, c.conname, pg_get_constraintdef(c.oid)
    from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
   where n.nspname = 'public' and c.contype = 'f'
   order by t.relname, c.conname
`);

const functions = psql(`
  select p.proname, pg_get_function_arguments(p.oid), pg_get_function_result(p.oid)
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f'
   order by p.proname
`);

let out = `/**
 * Database types — GENERATED FILE. Do not edit.
 *
 * Regenerate with:  node scripts/generate-types.mjs
 * (or, once Supabase is current: supabase gen types typescript --project-id <ref>)
 *
 * \`numeric\` columns are typed as \`string\`. That is deliberate and matches what
 * PostgREST sends: a JS number cannot represent them exactly, and money must be
 * exact. Parse them with \`fromDb()\` in src/lib/money.ts.
 */

export type Json = string | number | boolean | null | { [key: string]: Json } | Json[];

type Insertable<T, R extends keyof T> = Partial<Omit<T, R>> & Pick<T, R>;

`;

// Populated by BEFORE INSERT triggers rather than column defaults.
const TRIGGER_FILLED = {
  customers: ['customer_code'],
  purchase_bills: ['bill_number'],
  inventory_transactions: ['balance_after'],
  cash_transactions: ['balance_after'],
  bank_transactions: ['balance_after'],
  finance_transactions: ['balance_after'],
};

const rowNames = new Map();

for (const table of tables) {
  const cols = columns.filter((c) => c[0] === table);
  const unions = unionsFor(checks.filter((c) => c[0] === table).map((c) => [null, c[1]]));
  const rowName = table.replace(/(^|_)([a-z])/g, (_, __, ch) => ch.toUpperCase()) + 'Row';
  rowNames.set(table, rowName);

  out += `type ${rowName} = {\n`;
  const required = [];
  // Columns a BEFORE INSERT trigger populates. The database has no DEFAULT for
  // them, so introspection sees them as required — but the caller must not send
  // them, and in some cases (customer_code) must not be able to.
  const triggerFilled = TRIGGER_FILLED[table] ?? [];
  for (const [, name, dataType, udt, nullable, def, generated, identity] of cols) {
    const base = unions.get(name) ?? tsType(dataType, udt);
    out += `  ${name}: ${base}${nullable === 'YES' ? ' | null' : ''};\n`;
    const hasDefault =
      def !== '' || generated === 'ALWAYS' || identity === 'YES' || triggerFilled.includes(name);
    if (nullable === 'NO' && !hasDefault) required.push(name);
  }
  out += `};\n\n`;

  // Insert requires exactly the NOT NULL columns with no default.
  const req = required.length > 0 ? required.map((r) => `'${r}'`).join(' | ') : 'never';
  out += `type ${rowName}Insert = ${
    required.length > 0 ? `Insertable<${rowName}, ${req}>` : `Partial<${rowName}>`
  };\n\n`;
}

out += `export interface Database {\n  public: {\n    Tables: {\n`;

for (const table of tables) {
  const rowName = rowNames.get(table);
  const rels = fks
    .filter((f) => f[0] === table)
    .map(([, name, def]) => {
      const m = /FOREIGN KEY \(([^)]+)\) REFERENCES ([\w.]+)\(([^)]+)\)/.exec(def);
      if (!m) return null;
      const cols = m[1].split(',').map((c) => `'${c.trim()}'`).join(', ');
      const ref = m[2].replace(/^public\./, '');
      const refCols = m[3].split(',').map((c) => `'${c.trim()}'`).join(', ');
      return `          {\n            foreignKeyName: '${name}';\n            columns: [${cols}];\n            isOneToOne: false;\n            referencedRelation: '${ref}';\n            referencedColumns: [${refCols}];\n          },`;
    })
    .filter(Boolean);

  out += `      ${table}: {\n        Row: ${rowName};\n        Insert: ${rowName}Insert;\n        Update: Partial<${rowName}>;\n`;
  out += rels.length > 0 ? `        Relationships: [\n${rels.join('\n')}\n        ];\n` : `        Relationships: [];\n`;
  out += `      };\n`;
}

out += `    };\n    Views: Record<string, never>;\n    Functions: {\n`;

// Only the report/helper functions the application calls via rpc().
const RPC = new Set([
  'account_balances', 'trial_balance', 'profit_and_loss', 'balance_sheet',
  'vehicle_stock_report', 'inventory_stock_report', 'sales_summary', 'gst_summary',
  'customer_ledger', 'resolve_tax_code', 'resolve_vehicle_price', 'resolve_account',
  'allocate_stock', 'finance_company_ledger', 'post_vehicle_sale', 'consume_fitting_stock',
  'create_booking_with_advance', 'record_sale_payment', 'deliver_vehicle', 'next_document_number',
  'create_vehicle_sale_draft',
  // Cash book — spec §36, §37.
  'ensure_cash_day', 'record_cash_transaction', 'close_cash_day', 'reopen_cash_day', 'cash_book',
  // Bank and reconciliation — spec §38, §39.
  'record_bank_transaction', 'import_bank_statement', 'suggest_bank_matches', 'match_bank_line',
  'unmatch_bank_line', 'ignore_bank_line', 'complete_bank_reconciliation', 'bank_book',
  // Service workshop — spec §32, §33.
  'create_job_card', 'create_service_invoice', 'add_service_line', 'remove_service_line',
  'post_service_invoice', 'record_service_payment', 'service_history',
  // GST returns and the IRP queue — spec §40.
  'gstr1_summary', 'gst_document_register', 'queue_einvoice', 'record_einvoice_result',
  'queue_eway_bill', 'einvoice_queue',
  // MIS — spec §41, §43.
  'finance_summary', 'branch_performance', 'margin_report', 'consolidated_mis',
  'inventory_movement_report',
  // Transfers, adjustments and returns — spec §21, §34, §35.
  'dispatch_vehicle_transfer', 'receive_vehicle_transfer', 'transfer_inventory_stock',
  'adjust_inventory_stock', 'return_vehicle_sale',
  // Subsidiary ledgers — spec §11, §41.
  'customer_ledger_opening', 'party_ledger', 'party_ledger_opening',
  // Bill-wise settlement — spec §41.
  'party_open_items', 'allocate_party_payment',
  // Purchases — spec §24, §41.
  'post_purchase_bill', 'cancel_purchase_bill', 'unbilled_vehicles',
  // HR — spec §12, §15.
  'employee_salary_on',
  // Attendance integration — spec §12, §40.
  'start_attendance_sync', 'import_attendance_days', 'finish_attendance_sync',
  'attendance_summary',
  // Tenant provisioning — spec §4, §48.
  'dealer_readiness', 'purge_dealer', 'provision_dealer',
  // Finance operations — spec §25, §26, §27.
  'create_finance_application', 'decide_finance_application', 'disburse_finance_application',
  'record_trade_advance', 'create_finance_settlement', 'post_finance_settlement',
  // Price approval — spec §15.
  'decide_price_version',
  // Customer 360 — spec §11, §33.
  'customer_service_summary',
  // Booking advances — spec §18, §23.
  'refund_booking_advance',
  // Counter sales — spec §33.
  'create_counter_invoice',
  // E-invoice transmission — spec §40.
  'einvoice_payload', 'record_einvoice_request',
]);

function argsType(args) {
  if (!args.trim()) return 'Record<string, never>';
  const parts = args.split(',').map((a) => a.trim()).filter(Boolean);
  const fields = parts.map((part) => {
    const hasDefault = /DEFAULT/i.test(part);
    const cleaned = part.replace(/\s+DEFAULT.*$/i, '');
    const [name, ...rest] = cleaned.split(/\s+/);
    const pg = rest.join(' ');

    // A numeric ARGUMENT is sent as a JSON number, unlike a numeric COLUMN which
    // comes back as a string to preserve precision. Typing arguments as strings
    // would force every caller to stringify amounts for no reason.
    const ts = pg.startsWith('numeric')
      ? 'number'
      : pg === 'jsonb' || pg === 'json'
        ? 'Json'
        : tsType(pg, pg);

    return `${name}${hasDefault ? '?' : ''}: ${ts}${hasDefault ? ' | null' : ''}`;
  });
  return `{ ${fields.join('; ')} }`;
}

function returnsType(result) {
  if (result.startsWith('TABLE(')) {
    const inner = result.slice(6, -1);
    const fields = inner.split(',').map((f) => {
      const trimmedField = f.trim();
      const idx = trimmedField.indexOf(' ');
      const name = trimmedField.slice(0, idx);
      const pg = trimmedField.slice(idx + 1);
      return `${name}: ${tsType(pg.startsWith('numeric') ? 'numeric' : pg, pg)}`;
    });
    return `{ ${fields.join('; ')} }[]`;
  }
  if (result === 'uuid' || result === 'text') return 'string';
  if (result === 'void') return 'undefined';
  if (result === 'boolean') return 'boolean';
  return 'unknown';
}

for (const [name, args, result] of functions) {
  if (!RPC.has(name)) continue;
  out += `      ${name}: {\n        Args: ${argsType(args)};\n        Returns: ${returnsType(result)};\n      };\n`;
}

out += `    };\n    Enums: Record<string, never>;\n    CompositeTypes: Record<string, never>;\n  };\n}\n\n`;
out += `export type Tables<T extends keyof Database['public']['Tables']> =\n  Database['public']['Tables'][T]['Row'];\n\n`;
out += `export type AccountType = ChartOfAccountsRow['account_type'];\n`;
out += `export type JournalStatus = JournalEntriesRow['status'];\n`;
out += `export type AccountBalance = Database['public']['Functions']['account_balances']['Returns'][number];\n`;

writeFileSync(OUT, out);
console.log(`wrote ${OUT}`);
console.log(`  ${tables.length} tables, ${functions.filter(([n]) => RPC.has(n)).length} rpc functions`);
