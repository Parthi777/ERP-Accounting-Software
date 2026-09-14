/**
 * Stub for the `server-only` package.
 *
 * The real one exports `./empty.js` only under the `react-server` export
 * condition; its default entry is a bare `throw`, which is the whole point of
 * the package — it makes importing a server module from a client bundle fail
 * loudly at build time.
 *
 * Under Vitest there is no such condition, so any module carrying
 * `import 'server-only'` throws on import and cannot be tested at all. Aliasing
 * to this file is the narrow fix. The alternative — adding `react-server` to
 * `resolve.conditions` — changes how every dependency resolves and interacts
 * badly with Vitest's externalisation of node_modules.
 */
export {};
