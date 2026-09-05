# TW ERP — Two Wheeler Dealer ERP

Multi-tenant, accounting-first ERP for two-wheeler dealers. Built to the specification in
[CLAUDE.md](CLAUDE.md).

**Status: all eight phases built.** Every module in the specification has a working screen — 70
navigable routes, none of them placeholders. The foundation (tenancy, roles, audit, document
numbering, the posting engine) is joined by masters, pricing with approval, vehicle and parts
inventory, bookings and sales, service and counter sales, finance, cash and bank, GST, and the
consolidated MIS.

Verified by `npm run verify`: 47 migrations, 17 test files and 439 database assertions run
against a throwaway PostgreSQL instance on every check.

---

## Quick start

```bash
npm install
cp .env.example .env.local     # fill in your Supabase values
npm run dev                    # http://localhost:3000
```

Without Supabase configured the app still boots and serves `/setup`, which lists exactly what is
missing. See [docs/deployment-railway.md](docs/deployment-railway.md) for provisioning.

### Applying the database

One command applies every migration in order plus the seeds, stopping at the first error:

```bash
DATABASE_URL='postgresql://...' WITH_DEMO=1 bash scripts/apply-to-supabase.sh
```

Drop `WITH_DEMO=1` in production — it loads the demo ledger that gives the dashboard its figures.

**Already have an earlier version applied?** Re-running the full script fails on the first table
that already exists. Bundle only what is missing instead:

```bash
FROM=0013 npm run db:incremental      # writes supabase/INCREMENTAL-0013-to-<latest>.sql
```

Both bundles are wrapped in a single transaction: a failure rolls the whole thing back, so there is
never a half-applied schema to clean up.

Then create the logins in **Authentication → Users** and run:

```bash
psql "$DATABASE_URL" -f scripts/link-auth-users.sql
```

Logins must be created through Supabase Auth so it owns the password hash, which means their user
ids cannot be predicted by a seed file. `link-auth-users.sql` matches the accounts by email and wires
up the profile, role, branch access and employee link. It prints who was linked and what each of them
can now do.

### The first platform administrator

Onboarding dealers is done by a **platform administrator**, and there is no platform administrator
until you make one. `seed.sql` creates one only against the local test database — on a real Supabase
project it is skipped, because Supabase Auth owns account creation.

Add the login in **Authentication → Users**, then edit the one marked line in
`scripts/create-platform-admin.sql` and run it:

```bash
psql "$DATABASE_URL" -f scripts/create-platform-admin.sql
```

Use an address that is not one of your dealer logins. A platform admin has no tenant of its own on
purpose: `app.is_platform_admin()` bypasses every RLS policy, so an account that is both a platform
admin *and* attached to a dealer would see every tenant's data mixed into its own screens.

Sign in as that account and **Administration → Dealers** becomes the tenant console, with
**New tenant** on it.

`seed.sql` also creates a demo dealer with three branches and eight employees. Remove it before going
live with `psql "$DATABASE_URL" -f scripts/remove-demo-dealer.sql`, which keeps the permission
catalogue, the system roles and the audit trail.

---

## Scripts

| Command | Purpose |
|---|---|
| `npm run dev` | Development server |
| `npm run build` | Production build (standalone output for Railway) |
| `npm run typecheck` | `tsc --noEmit` |
| `npm run lint` | ESLint, including the architectural boundary rule |
| `npm run check:permissions` | Fails if the TS permission registry and SQL seed disagree |
| `npm run check:nav` | Fails if a sidebar entry's status disagrees with whether its page is built |
| `npm run types:generate` | Regenerates `src/types/database.types.ts` from the migrations |
| `npm run db:verify` | Applies migrations, seeds and integrity tests to a throwaway local database |
| `scripts/apply-to-supabase.sh` | Applies migrations and seeds to a live database via `DATABASE_URL` |
| `scripts/create-platform-admin.sql` | Grants an existing login platform administration, so it can onboard dealers |
| `scripts/link-auth-users.sql` | Links Supabase Auth accounts to profiles, roles and branch access |
| `npm run verify` | All of the above, in order |

`npm run db:verify` needs a local PostgreSQL 15+ server. It creates and drops
`twerp_migration_check` and never touches other databases.

---

## Architecture at a glance

```
Browser
  → proxy.ts            session refresh, auth gate
  → app/                pages and route handlers
  → server/services/    business rules, permission checks, field redaction
  → server/repositories/data access
  → Supabase PostgreSQL RLS, constraints, triggers
```

One rule holds the structure together: **nothing in `src/app` or `src/components` talks to the
database.** Route handlers and server actions call a service; services call repositories. This is
enforced by ESLint, not by convention alone.

Detail lives in [docs/architecture.md](docs/architecture.md).

---

## What the database guarantees

These are enforced by PostgreSQL, so no application bug can bypass them. Each is covered by a test in
`supabase/test/`.

- **Tenant isolation.** RLS on every table. A session cannot read or write another dealer's rows.
- **Branch isolation.** Users without all-branch access see only their granted branches.
- **No cross-tenant references.** Composite foreign keys make it structurally impossible to attach
  one dealer's record to another dealer's branch.
- **Double entry.** A journal cannot post unless total debit equals total credit and it has at least
  two lines.
- **Journal immutability.** A posted journal cannot be edited or deleted. Corrections are reversals,
  and a reversal must state a reason.
- **Append-only audit.** Audit rows cannot be updated or deleted by anyone, including an admin.
- **Safe document numbers.** Issued under a row lock in the database, never in the browser.
- **Idempotency.** A duplicate business reference on a journal is rejected by a unique index.

Run `npm run db:verify` to see every assertion execute — 439 of them, across 17 files.

---

## Money

Amounts are integer paise throughout `src/lib/money.ts`, and `numeric(18,4)` in the database. Float
arithmetic on money is never correct at scale — a trial balance that fails to balance by a rupee is
worse than useless. Values arrive from PostgREST as strings and are parsed digit by digit.

Display uses Indian grouping: `₹1,25,000.00`.

---

## Permissions

Authorization is permission-based, never role-name-based. Codes are defined once in
[`src/lib/permissions/registry.ts`](src/lib/permissions/registry.ts) (107 across 15 modules) and
seeded into the database; `npm run check:permissions` fails the build if the two drift.

Seven restricted permissions gate cost, margin, profit and commission. A role without them does not
merely have those fields hidden — `scrubRestrictedFields()` removes them from the payload at the
service boundary, so they never reach the browser.

See [docs/permissions.md](docs/permissions.md) for the role matrix.

---

## Documentation

| Document | Contents |
|---|---|
| [CLAUDE.md](CLAUDE.md) | The product specification |
| [docs/architecture.md](docs/architecture.md) | Layers, boundaries, where logic belongs |
| [docs/database.md](docs/database.md) | Schema, RLS model, helper functions, migration order |
| [docs/deployment-railway.md](docs/deployment-railway.md) | Supabase provisioning, Railway deploy, env vars |
| [docs/design-system.md](docs/design-system.md) | Glass tokens, when glass applies and when it does not |
| [docs/permissions.md](docs/permissions.md) | Role × permission matrix |

---

## Stack

Next.js 16 (App Router) · React 19 · TypeScript 5.9 · Tailwind CSS v4 · Supabase (PostgreSQL, Auth,
RLS) · TanStack Query · React Hook Form + Zod · Recharts · Railway
