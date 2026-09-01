/**
 * Fails the build when a navigation entry's `status` disagrees with whether its
 * page is actually built.
 *
 * The sidebar badges every `planned` item with the phase it is due in. Nothing
 * stops that drifting as modules ship, and the drift is not cosmetic in either
 * direction: a shipped module still marked `planned` tells users their working
 * screen has not arrived yet, and a placeholder marked `ready` sends them to an
 * empty page with no warning. Both misreport the product to the person using it.
 *
 * "Built" means the route's page does not render <ModulePlaceholder>, which is
 * the same signal a reader would use.
 *
 *   npm run check:nav
 */

import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');
const navPath = join(root, 'src', 'config', 'navigation.ts');

interface NavEntry {
  href: string;
  status: 'ready' | 'planned';
  line: number;
}

function parseNav(): NavEntry[] {
  const lines = readFileSync(navPath, 'utf8').split('\n');
  const entries: NavEntry[] = [];

  lines.forEach((text, index) => {
    const href = text.match(/href:\s*'([^']+)'/)?.[1];
    const status = text.match(/status:\s*'(ready|planned)'/)?.[1];
    if (href && status) {
      entries.push({ href, status: status as NavEntry['status'], line: index + 1 });
    }
  });

  return entries;
}

/** A route is built when its page exists and is not a placeholder. */
function isBuilt(href: string): { exists: boolean; built: boolean } {
  const page = join(root, 'src', 'app', '(app)', href === '/' ? '' : href, 'page.tsx');
  if (!existsSync(page)) {
    return { exists: false, built: false };
  }
  return { exists: true, built: !readFileSync(page, 'utf8').includes('ModulePlaceholder') };
}

function main(): void {
  const entries = parseNav();

  if (entries.length === 0) {
    console.error('\n  ✗ Parsed zero navigation entries — the format may have changed.\n');
    process.exit(1);
  }

  const problems: string[] = [];

  for (const entry of entries) {
    const { exists, built } = isBuilt(entry.href);

    if (!exists) {
      problems.push(
        `no page:            ${entry.href} (navigation.ts:${entry.line}) — the sidebar links nowhere`,
      );
      continue;
    }
    if (built && entry.status !== 'ready') {
      problems.push(
        `built but 'planned': ${entry.href} (navigation.ts:${entry.line}) — the sidebar badges a working screen as unbuilt`,
      );
    }
    if (!built && entry.status !== 'planned') {
      problems.push(
        `placeholder but 'ready': ${entry.href} (navigation.ts:${entry.line}) — the sidebar promises a screen that is not there`,
      );
    }
  }

  if (problems.length > 0) {
    console.error('\n  Navigation status does not match what is built:\n');
    for (const problem of problems) {
      console.error(`    ${problem}`);
    }
    console.error('\n  Update the status in src/config/navigation.ts so it tracks reality.\n');
    process.exit(1);
  }

  const ready = entries.filter((e) => e.status === 'ready').length;
  console.log(
    `  ✓ ${entries.length} navigation entries match their pages (${ready} ready, ${entries.length - ready} placeholder).`,
  );
}

main();
