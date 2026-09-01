/**
 * check-exports.ts — the export buttons and the export registry must agree
 *
 *   npx tsx scripts/check-exports.ts   (runs as part of `npm run verify`)
 *
 * An <ExportButtons report="..."/> naming a report the registry does not have
 * fails at runtime with a 404, and only for whoever clicks it. Nothing else in
 * the build connects the two — the id is a string on one side and a map key on
 * the other — so this is the thing that catches a typo or a rename.
 *
 * It also reports registry entries no screen offers. That is a warning rather
 * than a failure: a report can legitimately be reachable only by URL, and the
 * inventory report picks its id from an expression this cannot read.
 */
import fs from 'node:fs';
import path from 'node:path';

const ROOT = process.cwd();
const APP_DIR = path.join(ROOT, 'src/app/(app)');
const REPORTS_DIR = path.join(ROOT, 'src/server/export/reports');

function walk(dir: string): string[] {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) return walk(full);
    return entry.isFile() && full.endsWith('.tsx') ? [full] : [];
  });
}

// ── What the registry defines ───────────────────────────────────────────────
// Read from source rather than by importing: the registry and the services it
// pulls in are marked `server-only`, which refuses to load outside a request.
const registered = new Set<string>();
const columnProblems: string[] = [];

for (const file of fs.readdirSync(REPORTS_DIR)) {
  if (!file.endsWith('.ts')) continue;
  const source = fs.readFileSync(path.join(REPORTS_DIR, file), 'utf8');

  // One block per report. A block ends where the next report begins, so a
  // report at the end of a file does not swallow the shared column helpers
  // defined below the array.
  const blocks = source.split('defineReport<').slice(1);

  for (const block of blocks) {
    const id = block.match(/id: '([a-z0-9-]+)',/)?.[1];
    if (!id) continue;
    registered.add(id);

    // Only reports that spell their columns out inline can be checked here.
    // Several share a helper (`columns: () => ledgerColumns()`), whose keys live
    // outside the block and are checked once, wherever they are declared.
    const inline = block.match(/columns: \([^)]*\) =>[\s\S]*?\n    \],/)?.[0];
    if (!inline) continue;

    const keys = [...inline.matchAll(/\{\s*key: '([A-Za-z0-9_]+)'/g)].map((m) => m[1]!);
    if (keys.length === 0) {
      columnProblems.push(`${id}: columns resolve to nothing`);
      continue;
    }

    // A duplicate key makes two columns share one entry in the totals map, so
    // one of them silently prints the other's total.
    const seen = new Set<string>();
    const duplicates = keys.filter((k) => (seen.has(k) ? true : (seen.add(k), false)));
    if (duplicates.length > 0) {
      columnProblems.push(`${id}: duplicate column key(s) ${[...new Set(duplicates)].join(', ')}`);
    }
  }
}

// ── What the screens ask for ────────────────────────────────────────────────
// Both the literal form and the ids named inside a computed expression, so a
// page that switches report by view is still covered.
const referenced = new Map<string, string[]>();
for (const file of walk(APP_DIR)) {
  const source = fs.readFileSync(file, 'utf8');
  if (!source.includes('ExportButtons')) continue;

  const relative = path.relative(ROOT, file);
  const ids = new Set<string>();

  for (const match of source.matchAll(/report=\{?"([a-z0-9-]+)"/g)) ids.add(match[1]!);
  for (const match of source.matchAll(/report=\{[\s\S]*?\}\s*\n/g)) {
    for (const inner of match[0].matchAll(/'([a-z0-9-]+)'/g)) ids.add(inner[1]!);
  }

  for (const id of ids) {
    referenced.set(id, [...(referenced.get(id) ?? []), relative]);
  }
}

// ── Compare ─────────────────────────────────────────────────────────────────
const unknown = [...referenced.keys()].filter((id) => !registered.has(id)).sort();
const unused = [...registered].filter((id) => !referenced.has(id)).sort();

for (const id of unknown) {
  console.error(`  ✗ "${id}" is not in the export registry`);
  for (const file of referenced.get(id) ?? []) console.error(`      used in ${file}`);
}

if (unused.length > 0) {
  console.log(`  note: ${unused.length} report(s) reachable only by URL: ${unused.join(', ')}`);
}

for (const problem of columnProblems) console.error(`  ✗ ${problem}`);

if (unknown.length > 0 || columnProblems.length > 0) {
  console.error(
    `\n${unknown.length} unknown report id(s), ${columnProblems.length} column problem(s).`,
  );
  process.exit(1);
}

console.log(
  `Exports: ${registered.size} reports registered, ${referenced.size} offered across ${
    new Set([...referenced.values()].flat()).size
  } screens.`,
);
