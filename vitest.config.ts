import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { defineConfig } from 'vitest/config';
import tsconfigPaths from 'vite-tsconfig-paths';

// `import.meta.dirname` needs Node >= 20.11 and package.json declares >= 20.9.0,
// so the older spelling is the one that matches what this project claims to run on.
const here = dirname(fileURLToPath(import.meta.url));

export default defineConfig({
  plugins: [tsconfigPaths()],
  resolve: {
    alias: {
      // See test/stubs/server-only.ts — without this, every module with
      // `import 'server-only'` throws on import under Node.
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
    clearMocks: true,
  },
});
