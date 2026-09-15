import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { defineConfig } from 'vitest/config';

// `.mts`, not `.ts`: Vite's native config loader reads a `.ts` config as
// CommonJS unless package.json says `"type": "module"`, which this package
// cannot say without changing how Next treats every other file.
//
// `import.meta.dirname` needs Node >= 20.11 and package.json declares >= 20.9.0,
// so the older spelling matches what this project claims to run on.
const here = dirname(fileURLToPath(import.meta.url));

export default defineConfig({
  resolve: {
    // Native since Vite 7 — the vite-tsconfig-paths plugin is no longer needed
    // to resolve the `@/` alias from tsconfig.json.
    tsconfigPaths: true,
    alias: {
      // See test/stubs/server-only.ts — without this, every module carrying
      // `import 'server-only'` throws on import under Node and cannot be tested.
      'server-only': join(here, 'test/stubs/server-only.ts'),
    },
  },
  test: {
    environment: 'node',
    setupFiles: [join(here, 'test/setup.ts')],
    // Tests sit beside their sources. tsconfig already includes **/*.ts, so they
    // are type-checked by `npm run typecheck` for free, and Next only bundles
    // what a route imports — a test file never reaches the standalone output.
    include: ['src/**/*.test.ts'],
    // e2e/ belongs to Playwright; Vitest must not try to run those.
    exclude: ['e2e/**', 'node_modules/**'],
    clearMocks: true,
  },
});
