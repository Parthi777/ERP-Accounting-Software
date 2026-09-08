/**
 * Fails the build when supabase/ALL-IN-ONE.sql has drifted from the migrations
 * on disk.
 *
 * The bundles are generated files, and nothing about writing a migration forces
 * anyone to regenerate them. That drift has already shipped twice: once five
 * migrations behind, and again with 0058_gst_input_tax.sql missing. Neither was
 * caught, because `npm run db:verify` applies supabase/migrations/ directly and
 * never reads the bundle at all.
 *
 * The cost of the drift is not a stale file. The bundle is how a new Supabase
 * project gets its schema, so a missing migration means the next dealer to be
 * provisioned silently gets a database with a module's tables absent — and finds
 * out when a screen fails in front of a customer.
 *
 * Three things are checked:
 *
 *   1. Every migration on disk appears in each bundle, in the same order.
 *   2. The production bundle carries no demo data, and the demo bundle does.
 *      These were one file until the production copy shipped the demo dealer
 *      behind a comment asking the operator to delete it by hand.
 *   3. supabase/seed.sql is in both.
 *
 *   npm run check:bundle
 */

import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');

const MIGRATIONS_DIR = join(root, 'supabase', 'migrations');
const DEMO_SOURCE = 'scripts/seed-demo-data.sql';
const SEED_SOURCE = 'supabase/seed.sql';

/**
 * The banner opening the demo tenant inside supabase/seed.sql.
 *
 * seed.sql carries both the required permission catalogue and a demo dealer, so
 * "does the bundle include seed.sql" is not the question — "does it include the
 * half of seed.sql that invents a dealer" is. The generator cuts at the
 * @BUNDLE-CUT marker; this asserts the cut actually happened.
 */
const DEMO_TENANT_BANNER = '-- DEMO — one dealer, three branches, seven users';

interface Bundle {
  /** Path relative to the repo root, for messages. */
  readonly label: string;
  readonly path: string;
  /** Whether this bundle is meant to carry the demo dealer. */
  readonly demo: boolean;
}

const BUNDLES: Bundle[] = [
  { label: 'supabase/ALL-IN-ONE.sql', path: join(root, 'supabase', 'ALL-IN-ONE.sql'), demo: false },
  {
    label: 'supabase/ALL-IN-ONE-WITH-DEMO.sql',
    path: join(root, 'supabase', 'ALL-IN-ONE-WITH-DEMO.sql'),
    demo: true,
  },
];

/** Migration filenames on disk, in application order. */
function migrationsOnDisk(): string[] {
  return readdirSync(MIGRATIONS_DIR)
    .filter((name) => name.endsWith('.sql'))
    .sort();
}

/**
 * The migration filenames a bundle claims to contain.
 *
 * Read from the `-- SOURCE:` markers the generator writes, which is the same
 * signal a person scrolling the file would use.
 */
function migrationsInBundle(text: string): string[] {
  return [...text.matchAll(/^-- SOURCE: supabase\/migrations\/(.+\.sql)$/gm)].map((m) => m[1]!);
}

function main(): void {
  const onDisk = migrationsOnDisk();

  if (onDisk.length === 0) {
    console.error('\n  ✗ Found no migrations in supabase/migrations — the layout may have changed.\n');
    process.exit(1);
  }

  const problems: string[] = [];

  for (const bundle of BUNDLES) {
    if (!existsSync(bundle.path)) {
      problems.push(`${bundle.label} does not exist`);
      continue;
    }

    const text = readFileSync(bundle.path, 'utf8');
    const bundled = migrationsInBundle(text);

    const missing = onDisk.filter((name) => !bundled.includes(name));
    const extra = bundled.filter((name) => !onDisk.includes(name));

    for (const name of missing) {
      problems.push(`${bundle.label} is missing ${name} — a fresh install would not get it`);
    }
    for (const name of extra) {
      problems.push(`${bundle.label} contains ${name}, which is not in supabase/migrations`);
    }

    // Order matters as much as membership: migrations depend on the tables the
    // ones before them create, and the bundle is one transaction.
    if (missing.length === 0 && extra.length === 0) {
      const outOfOrder = bundled.findIndex((name, i) => name !== onDisk[i]);
      if (outOfOrder !== -1) {
        problems.push(
          `${bundle.label} applies migrations out of order — expected ${onDisk[outOfOrder]}, found ${bundled[outOfOrder]}`,
        );
      }
    }

    if (!text.includes(`-- SOURCE: ${SEED_SOURCE}`)) {
      problems.push(`${bundle.label} is missing ${SEED_SOURCE} — no permissions or system roles`);
    }

    // The permission catalogue must survive the cut in both bundles, or nobody
    // can be authorized for anything.
    if (!text.includes("('dashboard.view'")) {
      problems.push(
        `${bundle.label} carries no permission catalogue — the required half of ${SEED_SOURCE} was cut away`,
      );
    }

    const hasDemoTenant = text.includes(DEMO_TENANT_BANNER);
    if (bundle.demo && !hasDemoTenant) {
      problems.push(`${bundle.label} is the demo bundle but carries no demo tenant from ${SEED_SOURCE}`);
    }
    if (!bundle.demo && hasDemoTenant) {
      problems.push(
        `${bundle.label} is the production bundle and still carries the demo dealer from ${SEED_SOURCE} — the @BUNDLE-CUT cut did not happen`,
      );
    }

    const hasDemo = text.includes(`-- SOURCE: ${DEMO_SOURCE}`);
    if (bundle.demo && !hasDemo) {
      problems.push(`${bundle.label} is the demo bundle but carries no demo data`);
    }
    if (!bundle.demo && hasDemo) {
      problems.push(
        `${bundle.label} is the production bundle and carries the demo dealer — it would seed a fake dealer into a real database`,
      );
    }
  }

  if (problems.length > 0) {
    console.error('\n  The schema bundles do not match the migrations on disk:\n');
    for (const problem of problems) {
      console.error(`    ${problem}`);
    }
    console.error('\n  Regenerate them with: bash scripts/build-all-in-one.sh\n');
    process.exit(1);
  }

  console.log(
    `  ✓ Both schema bundles carry all ${onDisk.length} migrations in order (demo data only in ALL-IN-ONE-WITH-DEMO.sql).`,
  );
}

main();
