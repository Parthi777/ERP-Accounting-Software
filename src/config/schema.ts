/**
 * The migration this build of the application was written against.
 *
 * The application deploys to Railway on push while migrations are applied to
 * Supabase by hand, so the two can disagree. When they do, the failure surfaces
 * to whoever pressed a button as a PostgREST complaint about a function
 * signature — which names no cause, suggests no action, and is seen by the one
 * person who cannot fix it.
 *
 * Comparing this constant against `public.schema_migrations` (0059) turns that
 * into a statement an administrator can act on: the database is three migrations
 * behind, and here they are.
 *
 * Kept in step with `supabase/migrations/` by `npm run check:schema-version`,
 * which fails the build when they drift. It is a constant rather than a read of
 * the migrations directory because the standalone build does not ship that
 * directory — the value has to be baked in at build time.
 */
export const EXPECTED_SCHEMA_VERSION = '0060';
