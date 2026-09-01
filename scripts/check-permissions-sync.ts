/**
 * Fails the build when the TypeScript permission registry and the SQL seed
 * disagree.
 *
 * The two have to be written separately — one is application code, the other is
 * data the database needs before anyone can log in. Nothing stops them drifting
 * except a check like this, and drift here is not cosmetic: a permission present
 * in code but missing from the database is a check that silently always denies,
 * and one present in the database but missing from code is a grant nothing
 * enforces.
 *
 *   npm run check:permissions
 */

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { PERMISSIONS } from '../src/lib/permissions/registry';

const here = dirname(fileURLToPath(import.meta.url));
const seedPath = join(here, '..', 'supabase', 'seed.sql');

interface SeedPermission {
  code: string;
  module: string;
  sensitive: boolean;
}

function parseSeed(): SeedPermission[] {
  const sql = readFileSync(seedPath, 'utf8');

  // Isolate the INSERT ... INTO public.permissions VALUES block so that role
  // grants mentioning the same codes later in the file are not picked up.
  const start = sql.indexOf('insert into public.permissions');
  if (start === -1) {
    fail('Could not find the permissions INSERT in supabase/seed.sql.');
  }
  const end = sql.indexOf('on conflict', start);
  const block = sql.slice(start, end === -1 ? undefined : end);

  const rows: SeedPermission[] = [];
  const pattern = /\(\s*'([^']+)'\s*,\s*'([^']+)'\s*,\s*'((?:[^']|'')*)'\s*,\s*(true|false)\s*\)/g;

  for (const match of block.matchAll(pattern)) {
    rows.push({
      code: match[1]!,
      module: match[2]!,
      sensitive: match[4] === 'true',
    });
  }

  return rows;
}

function fail(message: string): never {
  console.error(`\n  ✗ ${message}\n`);
  process.exit(1);
}

function main(): void {
  const seed = parseSeed();

  if (seed.length === 0) {
    fail('Parsed zero permissions from supabase/seed.sql — the INSERT format may have changed.');
  }

  // Keyed by plain string: the point of the check is to compare against codes the
  // registry may not contain, which a `Permission`-keyed map would reject.
  const registryByCode = new Map<string, (typeof PERMISSIONS)[number]>(
    PERMISSIONS.map((p) => [p.code as string, p]),
  );
  const seedByCode = new Map<string, SeedPermission>(seed.map((p) => [p.code, p]));

  const problems: string[] = [];

  for (const permission of PERMISSIONS) {
    const seeded = seedByCode.get(permission.code);
    if (!seeded) {
      problems.push(`missing from seed.sql:  ${permission.code}`);
      continue;
    }
    if (seeded.module !== permission.module) {
      problems.push(
        `module mismatch:        ${permission.code} — registry "${permission.module}", seed "${seeded.module}"`,
      );
    }
    const registrySensitive = 'sensitive' in permission;
    if (seeded.sensitive !== registrySensitive) {
      problems.push(
        `sensitivity mismatch:   ${permission.code} — registry ${registrySensitive}, seed ${seeded.sensitive}`,
      );
    }
  }

  for (const permission of seed) {
    if (!registryByCode.has(permission.code)) {
      problems.push(`missing from registry:  ${permission.code}`);
    }
  }

  const duplicates = seed
    .map((p) => p.code)
    .filter((code, index, all) => all.indexOf(code) !== index);
  for (const code of new Set(duplicates)) {
    problems.push(`duplicated in seed.sql: ${code}`);
  }

  if (problems.length > 0) {
    console.error('\n  Permission registry and seed are out of sync:\n');
    for (const problem of problems) {
      console.error(`    ${problem}`);
    }
    console.error(
      `\n  Fix src/lib/permissions/registry.ts or supabase/seed.sql so the two agree.\n`,
    );
    process.exit(1);
  }

  const sensitiveCount = PERMISSIONS.filter((p) => 'sensitive' in p).length;
  const moduleCount = new Set(PERMISSIONS.map((p) => p.module)).size;
  console.log(
    `  ✓ ${PERMISSIONS.length} permissions in sync across ${moduleCount} modules (${sensitiveCount} restricted).`,
  );
}

main();
