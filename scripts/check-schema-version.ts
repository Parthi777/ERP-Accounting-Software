/**
 * Keeps the schema-version machinery honest in two directions.
 *
 * 1. `EXPECTED_SCHEMA_VERSION` in src/config/schema.ts must name the highest
 *    migration on disk. It is the value the running application compares the
 *    database against, so if it lags, the app reports a database as current when
 *    it is behind — worse than not checking at all, because it is reassuring.
 *
 * 2. Every migration from 0059 on must stamp itself into
 *    public.schema_migrations. That table is only as true as the last person to
 *    remember, and the whole point of it is to be trusted without asking.
 *
 * Migrations before 0059 are exempt: they are backfilled by 0059 itself, which
 * is the only honest way to record migrations that were applied before anything
 * was recording.
 *
 *   npm run check:schema-version
 */

import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');

const MIGRATIONS_DIR = join(root, 'supabase', 'migrations');
const CONFIG_PATH = join(root, 'src', 'config', 'schema.ts');

/** The first migration expected to stamp itself; earlier ones are backfilled. */
const STAMPING_STARTS_AT = '0059';

interface Migration {
  readonly version: string;
  readonly name: string;
  readonly file: string;
}

function migrations(): Migration[] {
  return readdirSync(MIGRATIONS_DIR)
    .filter((f) => f.endsWith('.sql'))
    .sort()
    .map((file) => {
      const match = /^(\d{4})_(.+)\.sql$/.exec(file);
      if (!match) {
        console.error(`\n  ✗ Migration filename does not match NNNN_name.sql: ${file}\n`);
        process.exit(1);
      }
      return { version: match[1]!, name: match[2]!, file };
    });
}

function declaredVersion(): string {
  const source = readFileSync(CONFIG_PATH, 'utf8');
  const match = /EXPECTED_SCHEMA_VERSION\s*=\s*'(\d{4})'/.exec(source);
  if (!match) {
    console.error('\n  ✗ Could not find EXPECTED_SCHEMA_VERSION in src/config/schema.ts.\n');
    process.exit(1);
  }
  return match[1]!;
}

/** Whether a migration writes its own row into public.schema_migrations. */
function stampsItself(m: Migration): boolean {
  const sql = readFileSync(join(MIGRATIONS_DIR, m.file), 'utf8');
  return (
    sql.includes('insert into public.schema_migrations') && sql.includes(`'${m.version}'`)
  );
}

function main(): void {
  const all = migrations();
  if (all.length === 0) {
    console.error('\n  ✗ Found no migrations in supabase/migrations.\n');
    process.exit(1);
  }

  const problems: string[] = [];

  const latest = all[all.length - 1]!;
  const declared = declaredVersion();
  if (declared !== latest.version) {
    problems.push(
      `EXPECTED_SCHEMA_VERSION is '${declared}' but the latest migration is ${latest.file} — ` +
        `set it to '${latest.version}' in src/config/schema.ts`,
    );
  }

  for (const m of all) {
    if (m.version < STAMPING_STARTS_AT) continue;
    if (!stampsItself(m)) {
      problems.push(
        `${m.file} does not stamp itself — add, as its last statement:\n` +
          `        insert into public.schema_migrations (version, name)\n` +
          `        values ('${m.version}', '${m.name}') on conflict (version) do nothing;`,
      );
    }
  }

  if (problems.length > 0) {
    console.error('\n  Schema version tracking is out of step:\n');
    for (const problem of problems) {
      console.error(`    ${problem}`);
    }
    console.error('');
    process.exit(1);
  }

  console.log(
    `  ✓ Schema version ${declared} matches the latest migration, and every migration from ${STAMPING_STARTS_AT} stamps itself.`,
  );
}

main();
