import nextCoreWebVitals from 'eslint-config-next/core-web-vitals';
import nextTypescript from 'eslint-config-next/typescript';

const config = [
  {
    ignores: ['.next/**', 'node_modules/**', 'next-env.d.ts'],
  },
  ...nextCoreWebVitals,
  ...nextTypescript,
  {
    rules: {
      '@typescript-eslint/no-unused-vars': [
        'error',
        { argsIgnorePattern: '^_', varsIgnorePattern: '^_' },
      ],
    },
  },
  {
    // Architectural boundary (spec §57.3): UI never reaches the database directly.
    // Route handlers and server actions call src/server/services/*, which own the rules.
    files: ['src/app/**/*.{ts,tsx}', 'src/components/**/*.{ts,tsx}'],
    rules: {
      'no-restricted-imports': [
        'error',
        {
          patterns: [
            {
              group: ['@/server/repositories/*', '**/server/repositories/*'],
              message:
                'UI must not import repositories. Call a service in src/server/services/ instead.',
            },
            {
              group: ['@/server/db/*', '**/server/db/*'],
              message:
                'UI must not construct database clients. Call a service in src/server/services/ instead.',
            },
          ],
        },
      ],
    },
  },
];

export default config;
