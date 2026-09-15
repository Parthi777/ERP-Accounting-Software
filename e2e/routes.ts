/**
 * Every route the sidebar offers, read from the navigation config at build time
 * rather than copied.
 *
 * A hand-kept list would drift the moment a module shipped, and the drift would
 * be silent: the suite would pass while covering less than it claims to.
 */
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

// Playwright runs specs from the project root, and its own loader treats these
// as CommonJS — so no import.meta here either.
export function navigableRoutes(): string[] {
  const source = readFileSync(join(process.cwd(), 'src', 'config', 'navigation.ts'), 'utf8');
  const hrefs = [...source.matchAll(/href:\s*'([^']+)'/g)].map((m) => m[1]!);
  return [...new Set(hrefs)];
}

/**
 * Pages that legitimately render an empty state or a form rather than data.
 * Listed so the assertions can be about *errors* rather than about content,
 * which would otherwise fail on a database with nothing in it.
 */
export const EXPECTED_EMPTY_OK = new Set<string>();
