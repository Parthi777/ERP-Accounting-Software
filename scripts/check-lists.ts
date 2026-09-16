/**
 * Fails the build when a hand-maintained list has drifted from the thing it is
 * supposed to describe.
 *
 * Three lists in this repo are written by hand and describe something the
 * database already knows. Nothing forces them to be updated when that something
 * changes, and all three have silently gone stale at least once:
 *
 *   1. The chart of accounts (spec §24) exists in three places — the base list
 *      in 0056's app.seed_chart_of_accounts, later migrations that add to it,
 *      and a separate copy in supabase/seed.sql for the demo dealer.
 *   2. TRIGGER_FILLED in scripts/generate-types.mjs — the columns a BEFORE
 *      INSERT trigger populates, which introspection cannot see. 0040 gave
 *      suppliers a code-issuing trigger and this map was not updated, so every
 *      TypeScript insert was forced to invent a supplier_code.
 *   3. The RPC set in the same file — the functions that reach the generated
 *      Database['public']['Functions'] types.
 *
 * The cost is not a stale file. A chart-of-accounts entry added for existing
 * dealers but not for new ones means the next dealer provisioned is missing an
 * account, and finds out when a posting function raises in front of a customer —
 * which is exactly what 3300 Opening Balance Equity would have done.
 *
 *   npm run check:lists
 */

import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');

const MIGRATIONS_DIR = join(root, 'supabase', 'migrations');
const SEED = join(root, 'supabase', 'seed.sql');
const GENERATOR = join(root, 'scripts', 'generate-types.mjs');
const TYPES = join(root, 'src', 'types', 'database.types.ts');

interface Account {
  readonly name: string;
  /** Absent where the statement took it from a loop variable rather than a literal. */
  readonly type?: string;
  readonly normalBalance?: string;
}

/**
 * Account codes are 1000–5999 under the spec §24 structure (assets through
 * expenses). The bound is what keeps this from matching migration version
 * stamps, which are four quoted digits followed by a quoted name in exactly the
 * same shape: ('0066', 'opening_balances').
 *
 * The name must contain a letter. Without that, `code in ('1100', '1300', ...)`
 * in 0056 reads as an account 1100 named "1300".
 */
const ACCOUNT_CODE =
  /'([1-5]\d{3})'\s*,\s*'((?=[^']*[A-Za-z])[^']{2,60})'(?:\s*,\s*'(ASSET|LIABILITY|EQUITY|INCOME|EXPENSE)'\s*,\s*'(DEBIT|CREDIT)')?/g;

/**
 * Every account a region of SQL names, as code → details.
 *
 * Both shapes in use are covered: a `values` table of full tuples, and an
 * `insert … values (p_dealer_id, '3300', 'Opening Balance Equity', …)` where the
 * code is not the first column. Neither anchors on the opening paren for that
 * reason.
 */
function accountsIn(sql: string): Map<string, Account> {
  const found = new Map<string, Account>();
  for (const m of sql.matchAll(ACCOUNT_CODE)) {
    const [, code, name, type, normalBalance] = m;
    const prev = found.get(code!);
    found.set(code!, {
      name: name!.trim(),
      type: type ?? prev?.type,
      normalBalance: normalBalance ?? prev?.normalBalance,
    });
  }
  return found;
}

function migrations(): { name: string; sql: string }[] {
  return readdirSync(MIGRATIONS_DIR)
    .filter((n) => n.endsWith('.sql'))
    .sort()
    .map((name) => ({ name, sql: readFileSync(join(MIGRATIONS_DIR, name), 'utf8') }));
}

// -----------------------------------------------------------------------------
// 1. The chart of accounts, in all three places
// -----------------------------------------------------------------------------
function checkChartOfAccounts(problems: string[]): number {
  // What a dealer provisioned today ends up with: the base list, plus every
  // account any later migration inserts. A migration that backfills an account
  // for existing dealers without adding it to the provisioning function is the
  // failure this catches — the backfilled dealers have it and the next new one
  // does not.
  const provisioned = new Map<string, Account>();
  const addedBy = new Map<string, string>();

  for (const { name, sql } of migrations()) {
    if (!sql.includes('chart_of_accounts')) continue;
    for (const [code, account] of accountsIn(sql)) {
      if (!provisioned.has(code)) addedBy.set(code, name);
      provisioned.set(code, { ...provisioned.get(code), ...account });
    }
  }

  const seedSql = readFileSync(SEED, 'utf8');
  const marker = '-- ── Chart of accounts (spec §24)';
  const start = seedSql.indexOf(marker);
  if (start === -1) {
    problems.push(
      `Could not find the chart of accounts in supabase/seed.sql — looked for "${marker}"`,
    );
    return 0;
  }
  const demo = accountsIn(seedSql.slice(start));

  for (const code of [...provisioned.keys()].sort()) {
    if (!demo.has(code)) {
      problems.push(
        `chart of accounts: ${code} ${provisioned.get(code)!.name} is provisioned by ` +
          `${addedBy.get(code)} but is missing from the demo dealer in supabase/seed.sql`,
      );
    }
  }
  for (const code of [...demo.keys()].sort()) {
    if (!provisioned.has(code)) {
      problems.push(
        `chart of accounts: ${code} ${demo.get(code)!.name} exists only for the demo dealer in ` +
          `supabase/seed.sql — a real dealer provisioned by app.seed_chart_of_accounts never gets it`,
      );
    }
  }
  for (const code of [...provisioned.keys()].sort()) {
    const a = provisioned.get(code)!;
    const b = demo.get(code);
    if (!b) continue;
    if (a.name !== b.name) {
      problems.push(`chart of accounts: ${code} is "${a.name}" in the migrations and "${b.name}" in seed.sql`);
    }
    if (a.type && b.type && a.type !== b.type) {
      problems.push(`chart of accounts: ${code} is ${a.type} in the migrations and ${b.type} in seed.sql`);
    }
    if (a.normalBalance && b.normalBalance && a.normalBalance !== b.normalBalance) {
      problems.push(
        `chart of accounts: ${code} is ${a.normalBalance} in the migrations and ${b.normalBalance} in seed.sql — ` +
          `a wrong normal balance inverts the account on every report`,
      );
    }
  }

  return provisioned.size;
}

// -----------------------------------------------------------------------------
// 2. TRIGGER_FILLED against the triggers themselves
// -----------------------------------------------------------------------------
/** The columns each BEFORE INSERT trigger assigns, derived from its function body. */
function triggerFilledColumns(): Map<string, Set<string>> {
  const all = migrations().map((m) => m.sql).join('\n');

  const bodies = new Map<string, string>();
  for (const m of all.matchAll(/create\s+(?:or\s+replace\s+)?function\s+([\w.]+)\s*\([^)]*\)(.*?)\$\$\s*;/gis)) {
    const name = m[1]!.toLowerCase();
    bodies.set(name, (bodies.get(name) ?? '') + m[2]!);
  }

  const filled = new Map<string, Set<string>>();
  const trigger =
    /create\s+trigger\s+\w+\s+before\s+insert[^;]*?\s+on\s+public\.(\w+)[^;]*?execute\s+(?:function|procedure)\s+([\w.]+)\s*\(/gis;

  for (const m of all.matchAll(trigger)) {
    const table = m[1]!.toLowerCase();
    const fn = m[2]!.toLowerCase();
    const body = bodies.get(fn) ?? bodies.get(`public.${fn}`) ?? bodies.get(fn.replace(/^public\./, '')) ?? '';
    for (const a of body.matchAll(/\bnew\.(\w+)\s*:=/gi)) {
      if (!filled.has(table)) filled.set(table, new Set());
      filled.get(table)!.add(a[1]!.toLowerCase());
    }
  }
  return filled;
}

/** table → the columns the generated Insert type still demands from the caller. */
function requiredInsertColumns(): Map<string, Set<string>> {
  const types = readFileSync(TYPES, 'utf8');

  const requiredByType = new Map<string, Set<string>>();
  for (const m of types.matchAll(/type\s+(\w+RowInsert)\s*=\s*Insertable<\w+,\s*([^>]+)>/g)) {
    requiredByType.set(m[1]!, new Set([...m[2]!.matchAll(/'([^']+)'/g)].map((x) => x[1]!)));
  }
  // `Partial<XRow>` — nothing required at all.
  for (const m of types.matchAll(/type\s+(\w+RowInsert)\s*=\s*Partial</g)) {
    requiredByType.set(m[1]!, new Set());
  }

  const byTable = new Map<string, Set<string>>();
  for (const m of types.matchAll(/^\s{6}(\w+):\s*\{\s*\n\s*Row:[^\n]*\n\s*Insert:\s*(\w+);/gm)) {
    byTable.set(m[1]!, requiredByType.get(m[2]!) ?? new Set());
  }
  return byTable;
}

function checkTriggerFilled(problems: string[]): number {
  const generator = readFileSync(GENERATOR, 'utf8');
  const start = generator.indexOf('const TRIGGER_FILLED = {');
  if (start === -1) {
    problems.push('Could not find TRIGGER_FILLED in scripts/generate-types.mjs');
    return 0;
  }
  const end = generator.indexOf('};', start);
  const block = generator.slice(start, end);

  const declared = new Map<string, Set<string>>();
  for (const m of block.matchAll(/^\s*(\w+):\s*\[([^\]]*)\]/gm)) {
    declared.set(m[1]!, new Set([...m[2]!.matchAll(/'([^']+)'/g)].map((x) => x[1]!)));
  }

  const actual = triggerFilledColumns();
  const required = requiredInsertColumns();

  // The condition that has already cost a bug, stated as what actually goes
  // wrong rather than as which file is stale: a column a trigger issues must
  // never be required in the committed Insert type, or every TypeScript insert
  // is forced to invent a value the database was going to supply. Columns that
  // are nullable or defaulted are optional either way and are not named here.
  //
  // Both causes reach the same symptom, so the message says which one it is.
  for (const [table, columns] of [...actual].sort()) {
    for (const column of [...columns].sort()) {
      if (!required.get(table)?.has(column)) continue;
      problems.push(
        declared.get(table)?.has(column)
          ? `TRIGGER_FILLED: ${table}.${column} is filled by a trigger and declared in ` +
            `scripts/generate-types.mjs, but src/types/database.types.ts still requires it — ` +
            `the types were generated before the map was fixed. Run npm run types:generate`
          : `TRIGGER_FILLED: a BEFORE INSERT trigger fills ${table}.${column}, but the map in ` +
            `scripts/generate-types.mjs does not say so — every TypeScript insert is forced to ` +
            `invent a value the database was going to issue`,
      );
    }
  }

  for (const [table, columns] of [...declared].sort()) {
    for (const column of [...columns].sort()) {
      if (actual.get(table)?.has(column)) continue;
      problems.push(
        `TRIGGER_FILLED: claims ${table}.${column} is filled by a trigger, but no BEFORE INSERT ` +
          `trigger on ${table} assigns it — if that trigger was dropped, inserts are now missing the column`,
      );
    }
  }

  return [...declared.values()].reduce((n, s) => n + s.size, 0);
}

// -----------------------------------------------------------------------------
// 3. The RPC set against the functions that exist and the ones the app calls
// -----------------------------------------------------------------------------
function checkRpcAllowlist(problems: string[]): number {
  const generator = readFileSync(GENERATOR, 'utf8');
  const start = generator.indexOf('const RPC = new Set([');
  if (start === -1) {
    problems.push('Could not find the RPC set in scripts/generate-types.mjs');
    return 0;
  }
  const end = generator.indexOf('])', start);
  const allowed = new Set([...generator.slice(start, end).matchAll(/'(\w+)'/g)].map((m) => m[1]!));

  const defined = new Set<string>();
  for (const { sql } of migrations()) {
    for (const m of sql.matchAll(/create\s+(?:or\s+replace\s+)?function\s+public\.(\w+)\s*\(/gi)) {
      defined.add(m[1]!);
    }
  }

  const called = new Set<string>();
  const srcDir = join(root, 'src');
  for (const entry of readdirSync(srcDir, { recursive: true, withFileTypes: true })) {
    if (!entry.isFile() || !/\.tsx?$/.test(entry.name)) continue;
    const text = readFileSync(join(entry.parentPath, entry.name), 'utf8');
    // Any quote style. The repo writes single quotes, but a double-quoted call
    // is still a call, and one that slipped through would be invisible here.
    for (const m of text.matchAll(/\.rpc\(\s*['"`](\w+)['"`]/g)) called.add(m[1]!);
  }

  for (const name of [...allowed].sort()) {
    if (!defined.has(name)) {
      problems.push(
        `RPC set: '${name}' is in the allowlist in scripts/generate-types.mjs but no migration ` +
          `creates public.${name} — the name is stale, or misspelled`,
      );
    }
  }
  for (const name of [...called].sort()) {
    if (!allowed.has(name)) {
      problems.push(
        `RPC set: src calls .rpc('${name}') but it is not in the allowlist in ` +
          `scripts/generate-types.mjs — it will be absent from the generated Functions types`,
      );
    }
  }

  return allowed.size;
}

function main(): void {
  const problems: string[] = [];

  const accounts = checkChartOfAccounts(problems);
  const triggerColumns = checkTriggerFilled(problems);
  const rpcs = checkRpcAllowlist(problems);

  if (problems.length > 0) {
    console.error('\n  A hand-maintained list has drifted from what it describes:\n');
    for (const problem of problems) console.error(`    ${problem}`);
    console.error('');
    process.exit(1);
  }

  console.log(
    `  ✓ Hand-maintained lists agree with the database (${accounts} accounts in all three ` +
      `copies, ${triggerColumns} trigger-filled columns, ${rpcs} RPCs).`,
  );
}

main();
