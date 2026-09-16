# Staging, and running the write-path suite safely

The Playwright write-path suite (`--project=flows`) submits real forms: it creates customers,
imports a CSV, posts and reverses a journal, takes a receipt and closes a cash day. Some of that
cannot be undone. **A posted journal is immutable by design** (spec §23), and
`public.purge_dealer()` refuses once anything is POSTED — a tenant that has posted can only be
set to `CLOSED`, never removed.

So these tests need somewhere of their own.

---

## Why not a throwaway dealer in production

It is tempting: RLS isolates tenants properly, and `dealer_readiness()` will happily provision a
second one. But every run posts journals, so each throwaway tenant becomes permanent and closed
rather than purged, and they accumulate inside a live accounting database for ever. Platform-level
figures and backups carry them. Don't.

## Why not a local stack

`npm run db:verify` creates a throwaway local PostgreSQL and applies every migration to it, which
is why the SQL suite can run unattended. It is not enough for the browser tests: the app needs
PostgREST and Supabase Auth, not just PostgreSQL, and `supabase/test/00_supabase_shim.sql` only
fakes `auth.uid()` well enough for SQL. A local stack needs the Supabase CLI and Docker.

---

## Standing up staging

1. **A second Supabase project.** Same region as production, free tier is fine. Nothing about it
   is shared with production — a separate project, not a separate schema.

2. **Apply the schema with demo data:**

   ```bash
   DATABASE_URL='postgresql://...staging...' WITH_DEMO=1 bash scripts/apply-to-supabase.sh
   ```

   `WITH_DEMO=1` is the opposite of the production advice, and deliberately: the demo dealer gives
   the flows customers, stock and a chart of accounts to work against.

3. **A login, through Supabase Auth** — Authentication → Users, then:

   ```bash
   psql "$DATABASE_URL" -f scripts/link-auth-users.sql
   ```

   Auth owns the password hash, so the account cannot be seeded; `link-auth-users.sql` matches by
   email and wires up the profile, role and branch access.

4. **A Railway environment** pointing at the staging project, or run the app locally against it.
   Note that `NEXT_PUBLIC_*` values are inlined at build time, so switching environments means a
   rebuild, not a restart.

---

## Running it

```bash
E2E_BASE_URL=https://staging.example.railway.app \
E2E_EMAIL=accounts@sribalajimotors.example \
E2E_PASSWORD='...' \
E2E_ALLOW_WRITES=1 \
E2E_WRITE_DEALER=SBM \
npm run test:e2e -- --project=flows
```

| Variable | Why |
|---|---|
| `E2E_BASE_URL` | Where to test. **Leave it unset and Playwright builds and starts the app from `.env.local`** — which in this repo is production |
| `E2E_EMAIL` / `E2E_PASSWORD` | The login `auth.setup.ts` signs in with |
| `E2E_ALLOW_WRITES` | Without `=1` every write test skips |
| `E2E_WRITE_DEALER` | The tenant these tests may write into, by dealer code |

### The guard

`E2E_WRITE_DEALER` is not a formality. Before any test writes, `assertWritableTenant()` reads
`data-dealer-code` off the app shell and refuses unless it matches:

```
Refusing to write. E2E_WRITE_DEALER is "SBM" but this app is signed into "DHARANI".
```

That is the check that catches the dangerous default. The suite's own header used to say "only
ever run against a throwaway tenant" and nothing enforced it, while the configuration pointed at
production unless you knew to override it. A comment is not a guard when the mistake has no undo.

The read-only suites need none of this:

```bash
npm run test:e2e                      # opens all 80 screens; no session writes
npm run test:e2e -- --project=smoke   # health, auth redirects, no login at all
```

---

## What the write suite covers, and what it does not

Covered today: creating a customer, a CSV import whose bad row blocks the whole file, a clean CSV
import, posting and reversing a manual journal, a double-clicked receipt writing one row, and
closing the cash day.

Not covered, and worth adding **against a working staging environment rather than blind** — the
fixtures in these flows depend on real screen behaviour, and writing them without being able to run
them produces tests that look like coverage and are not:

- booking → sale → delivery, the longest chain in the product, including the advance landing
  against the sale
- service job card → invoice → payment, with spares consumption reducing stock
- counter sale, with the LOCAL-before-COMPANY allocation visible on the invoice (spec §31)
- purchase bill → purchase return
- bank statement import → reconciliation

Each should assert the accounting consequence and not just the screen: the journal exists and
balances, stock moved, the ledger shows it. That is the style the existing flows already use when
they re-query `/customers?q=` rather than trusting the importer's own count.

---

## Known gaps this would close

`docs/database.md` records that the SQL shim is not Supabase: real JWT-derived `auth.uid()`, the
Supabase Auth signup and password-reset flows, and Storage are unverified until a real project
exists. A staging project is where those finally get exercised.
