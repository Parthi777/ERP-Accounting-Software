# Architecture

## The shape of a request

```
Browser
  │
  ├─ src/proxy.ts ───────────── refreshes the Supabase session, redirects anonymous traffic
  │
  ├─ src/app/**  ────────────── pages, layouts, route handlers, server actions
  │                             renders UI; holds no business rules
  │
  ├─ src/server/services/** ─── business rules, permission checks, field redaction
  │                             the only place a decision is made
  │
  ├─ src/server/repositories/** data access; queries and row mapping, nothing else
  │
  └─ Supabase PostgreSQL ────── RLS, constraints, triggers
                                the last word on what is allowed
```

## The one structural rule

**Nothing in `src/app` or `src/components` may reach the database.**

Pages and components call a service. Services call repositories. Repositories issue queries.

This is enforced by `no-restricted-imports` in `eslint.config.mjs`, not by convention — including for
type-only imports. When a page needs a row type, the service re-exports it (see
`src/server/services/org/org-service.ts`). An exception for types would erode a rule that is only
useful while it is absolute.

Spec §57.3 and §58 ask for exactly this: a transaction is not a form writing a row, it is
`User Action → Validation → Business Transaction → Accounting Event → Inventory Event → Ledger →
Audit → Reporting`. Each arrow needs a place to live.

## Layers

### `src/proxy.ts`

Refreshes the Supabase session cookie on every request and redirects unauthenticated traffic to
`/login`. Next 16 renamed this convention from `middleware`.

It calls `getUser()`, not `getSession()` — the latter trusts the cookie as presented, which is the
one thing an auth gate must not do. If Supabase is unreachable the request is treated as
unauthenticated: it fails closed.

**This is a convenience gate, not the security boundary.** A request that bypassed it entirely still
could not read another tenant's data, because authorization is decided in the service layer and
enforced by RLS.

### `src/server/auth/tenant-context.ts`

The security spine. `getTenantContext()` resolves — from the authenticated session and the database,
and from nowhere else — the user, their dealer, their accessible branches, their roles and their
permission set.

Spec §47 forbids trusting the client for: the user's role, `dealer_id`, `branch_id`, or margin
visibility. None of them are read from the request.

The single exception is *which* already-accessible branch is currently active, carried in a cookie.
`resolveActiveBranch()` validates that value against `accessibleBranches` before honouring it, so a
forged cookie silently falls back to the default branch.

Wrapped in React's `cache`, so a request rendering the sidebar, header and three server components
performs one round of lookups rather than five.

### `src/server/services/**`

Business rules. Every entry point:

1. asserts its permission — `const ctx = await requirePermission('sales.post')`
2. applies the rules
3. redacts restricted fields on the way out

The permission check belongs here rather than in the page so a future route handler or server action
hitting the same data cannot forget it.

### `src/server/repositories/**`

Queries and row mapping. No rules, no permission decisions.

Repositories deliberately **do not** add a `dealer_id` filter. Scoping is RLS's job. A filter the
application forgets is a leak; a policy the application forgets is still enforced.

### Database

The final authority. See [database.md](database.md).

## Server/client boundary

`src/config/navigation.ts` is evaluated on the server and its result handed to the client sidebar.
React cannot serialize functions across that boundary, so the config carries icon *names* and
`src/components/layout/nav-icons.ts` — client-side — maps them to components. Holding `LucideIcon`
values in the config throws *"Functions cannot be passed directly to Client Components"* at render
time.

Anything crossing into a client component must be serializable data. When a client component needs
to act on the server, it calls a server action (`src/server/auth/actions.ts`).

## Money

`src/lib/money.ts`. Integer paise everywhere; `numeric(18,4)` in the database.

`0.1 + 0.2 !== 0.3` in IEEE-754. An ERP summing thousands of invoice lines in floats produces a trial
balance that does not balance, and a trial balance that does not balance is not an accounting system.

PostgREST returns `numeric` as a string for the same reason. `fromDb()` parses those strings with
`BigInt` rather than `parseFloat`, so nothing is lost in transit.

`allocate()` splits an amount into parts that sum back exactly — ₹100 three ways is 33.34 / 33.33 /
33.33, never 99.99.

## Permissions and redaction

Codes live in `src/lib/permissions/registry.ts` and are seeded into `public.permissions`;
`npm run check:permissions` fails the build on drift. Drift is not cosmetic: a permission in code but
not the database is a check that always denies, and one in the database but not in code is a grant
nothing enforces.

`scrubRestrictedFields()` (in `src/lib/permissions/index.ts`) strips cost, COGS, margin, profit and
commission fields for sessions lacking the matching permission. It is keyed by field name and
recurses through nested objects, so a new module naming a column `gross_margin` is covered the moment
it is added to the map.

The dashboard service goes further: for a session without `dashboard.view_margin`, the margin KPIs
are never constructed. Spec §10 requires that a Cashier not *receive* these fields, which is stronger
than not displaying them.

## Errors

`src/server/errors/index.ts`. Each `AppError` carries a `userMessage` safe to render and a technical
`message` for the log. Spec §55: never fail silently, never show a raw error.

## Adding a module

1. Add its permissions to `src/lib/permissions/registry.ts` **and** `supabase/seed.sql`; run
   `npm run check:permissions`.
2. Write a migration: tables, constraints, indexes, RLS policies, audit triggers. Add cross-tenant
   composite foreign keys.
3. Add a test in `supabase/test/` asserting isolation and the module's own integrity rules.
4. Add a repository, then a service that checks permissions and redacts restricted fields.
5. Replace the placeholder page; set `status: 'ready'` in `src/config/navigation.ts`.
6. `npm run verify`.

## Report exports (PDF and Excel)

Every report screen offers an Excel and a PDF download. Both are generated on the
server by `GET /api/export/<report>?format=xlsx|pdf`, carrying the screen's own
query string so the file matches the filters on display.

The unit of the system is a **report registry entry** (`src/server/export/reports/`).
An entry names a permission, a loader, and a list of columns. The loader calls the
same service the page called — never the database — which is what makes an export
obey the same tenant scoping and the same restricted-field rules as the screen it
came from (§47, §52). Cost, margin and commission columns are dropped for sessions
that may not see them, so the header does not advertise what the data withholds.

    screen ──┐
             ├── service ── repository ── database
    export ──┘

Adding an export is a registry entry plus `<ExportButtons report="..."/>`; there is
no new route and no second copy of the query. `npm run check:exports` fails the
build if a button names a report that does not exist.

Three details worth knowing:

- **Money lands in Excel as a number in rupees**, with the Indian grouping format
  `#,##,##0.00`, not as a formatted string — the first thing anyone does with an
  export is sum a column, and `"₹1,25,000.00"` sums to zero. Dates land as dates.
- **Row caps are raised for exports and truncation is declared.** Screens cap at
  200–500 rows; exports ask for `EXPORT_ROW_CAP` (10,000). If a loader comes back
  with a full page, both renderers print an incomplete-export banner. A financial
  extract that quietly stops partway is worse than none.
- **The PDF embeds DejaVu Sans Condensed** (`src/server/export/fonts/`). The PDF
  base-fourteen fonts are WinAnsi and have no ₹, so the built-ins cannot render a
  single amount in this application. `next.config.ts` lists the directory under
  `outputFileTracingIncludes`, because file tracing follows imports and cannot see
  a font opened by path — without it the standalone build would fall back to
  Helvetica and print `INR`.

Every successful export writes an `EXPORT` audit row (§46): who, which report,
which filters, how many rows.
