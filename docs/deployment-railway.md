# Deployment — Supabase + Railway

```
User → Railway (Next.js standalone) → Supabase (PostgreSQL, Auth, Storage)
                                    → GST / e-invoice provider (when configured)
```

The application is stateless. Nothing business-critical is written to the Railway filesystem — the
container is replaced on every deploy (spec §3, §60.2).

---

## 1. Supabase

1. Create a project at [supabase.com](https://supabase.com). Choose a region close to your users;
   `ap-south-1` (Mumbai) for Indian dealers.
2. **Project Settings → API** gives you three values:
   - Project URL → `NEXT_PUBLIC_SUPABASE_URL`
   - `anon` / public key → `NEXT_PUBLIC_SUPABASE_ANON_KEY`
   - `service_role` key → `SUPABASE_SERVICE_ROLE_KEY`

The `service_role` key bypasses row level security entirely. It is server-only. Never prefix it with
`NEXT_PUBLIC_`, never import it into a client component, never commit it.

3. **Project Settings → Database** gives the connection string for `DATABASE_URL`. Use the *pooled*
   connection (port 6543) on Railway; direct connections (5432) do not survive a serverless
   connection count.

### Apply the schema

Through the SQL editor, or with `psql`:

```bash
for f in supabase/migrations/*.sql; do
  echo "→ $f"
  psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$f"
done

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/seed.sql
```

Order matters — later migrations depend on earlier ones. `0009` defines policies over tables from
`0002`–`0008`; `0004`'s helper functions are referenced by every policy.

For the SQL editor, two generated bundles concatenate all of that into a single transactional script:

| File | Contents | Verified to produce |
|---|---|---|
| `supabase/ALL-IN-ONE.sql` | Migrations + the required half of `seed.sql`. **Use this for a real dealer.** | 68 tables, 124 permissions, 7 system roles, **0 dealers** |
| `supabase/ALL-IN-ONE-WITH-DEMO.sql` | The same, plus the demo tenant and its trading data | the above, plus 1 dealer, 3 branches, 8 employees, a balancing ledger |

They were one file until the production copy carried the demo dealer behind a comment asking you to
delete that section by hand before running it. A manual deletion step fails silently, and it fails
towards a real dealer's database holding a fake dealer's ledger — so the choice is now which file you
open.

Note the split runs *inside* `supabase/seed.sql` as well as between files: that file holds the
required permission catalogue **and** a demo tenant, so the production bundle is cut at the
`@BUNDLE-CUT` marker in it. Cutting only `scripts/seed-demo-data.sql` would still have seeded a fake
dealer with three branches and seven users.

Regenerate both with `bash scripts/build-all-in-one.sh`; `npm run check:bundle` fails the build if
they drift from `supabase/migrations/`, if the cut did not happen, or if the permission catalogue
went missing.

`seed.sql` is **required**: it installs the permission catalogue and the seven system roles, without
which nobody can be authorized for anything. It also creates a demo dealer; the teardown for that is
documented at the top of the file.

`scripts/seed-demo-data.sql` is optional and demo-only. It trades a couple of months through the real
business functions — vehicle stock, bookings, sales, service, counter sales, finance and the cash and
bank books — so every screen has something on it and the ledger genuinely balances. Skip it in
production, or load it to check the deployment and then remove it with
`scripts/remove-demo-dealer.sql`.

### Verify before you deploy

If you have PostgreSQL 15+ locally:

```bash
npm run db:verify
```

This applies everything to a throwaway database and runs 64 integrity assertions. It is much cheaper
to find a migration problem here than in your Supabase project.

### Auth settings

**Authentication → URL Configuration**:

- Site URL: your Railway URL, e.g. `https://tw-erp.up.railway.app`
- Redirect URLs: add `https://<your-domain>/api/auth/callback` and
  `https://<your-domain>/reset-password`

Users are created through Supabase Auth. Each needs a matching `public.user_profiles` row carrying
their dealer and branch access — an authenticated user with no profile is treated as having no
session, which is deliberate: a half-provisioned account should not reach the application.

---

## 2. Railway

1. Create a project and point it at this repository. Nixpacks detects Next.js automatically;
   `railway.json` pins the build command, start command and health check.
2. Add the environment variables below under **Variables**.
3. Deploy.

`next.config.ts` sets `output: 'standalone'`, so the container ships only the server bundle and the
dependencies it actually uses.

**The bundle needs one thing Next does not put in it.** `output: 'standalone'` deliberately leaves
`.next/static` (the hashed CSS and JS chunks) and `public/` (the CSV import templates) outside the
bundle. Deploy without them and the app starts, passes its health check, and serves HTML where every
stylesheet and script 404s — which looks like a broken application rather than a missing copy step.

`scripts/prepare-standalone.sh` copies both, and runs automatically as npm's `postbuild`, so it
happens on Railway and locally without anyone remembering it.

**And the start command must pin the bind address.** Next's standalone server begins with:

```js
const hostname = process.env.HOSTNAME || '0.0.0.0'
```

Docker sets `HOSTNAME` to the container id, so on Railway that fallback never applies and the server
tries to bind to a name that does not resolve:

```
Error: getaddrinfo ENOTFOUND a1b2c3d4e5f6
⨯ Failed to start server
```

The process exits, Railway restarts it, and the domain answers **“Application failed to respond”** —
with nothing obviously wrong in the build log, because the build succeeded. `railway.json` therefore
starts the app as `HOSTNAME=0.0.0.0 node .next/standalone/server.js`. Keep that prefix if you change
the start command. If you change the build command in
`railway.json`, keep `npm run build` as the entry point rather than calling `next build` directly, or
the postbuild step is skipped and the site deploys blank.

### Environment variables

| Variable | Required | Notes |
|---|---|---|
| `NEXT_PUBLIC_SUPABASE_URL` | yes | Project URL |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | yes | Safe in the browser; RLS applies to it |
| `SUPABASE_SERVICE_ROLE_KEY` | yes | **Server only.** Bypasses RLS |
| `NEXT_PUBLIC_APP_URL` | yes | Public origin, for auth redirects |
| `APP_SECRET` | yes | 32+ chars. `openssl rand -base64 32` |
| `NODE_ENV` | **no — never set it** | Next sets it. Forcing `development` builds React's dev bundle and the build fails prerendering `/_global-error` with `Cannot read properties of null (reading 'useContext')` |
| `DATABASE_URL` | optional | Migration tooling and future transactional paths |
| `GST_API_*` | optional | E-invoice provider (spec §40) |
| `SUPABASE_STORAGE_BUCKET` | optional | Defaults to `tw-erp-documents` |

`src/config/env.ts` validates these with Zod at startup. Missing Supabase values do not crash the
app: it boots and serves `/setup`, listing exactly what is absent.

### Health check

`GET /api/health` returns 200 even when Supabase is unconfigured:

```json
{ "status": "ok", "configured": false, "version": "1.0.0", "timestamp": "…" }
```

This is intentional. A first deploy passes its health check and serves `/setup` instead of
crash-looping before anyone can add the variables. `configured` tells you which state you are in.

---

## Going live

- [ ] Every migration in `supabase/migrations/` applied, in order
- [ ] `seed.sql` applied (permissions and system roles)
- [ ] `scripts/seed-demo-data.sql` **not** applied, or applied and then removed
- [ ] Demo dealer removed — `psql "$DATABASE_URL" -f scripts/remove-demo-dealer.sql`
      (a plain `delete from public.dealers` cannot work: financial history is `on delete restrict`
      and the stock and finance ledgers are append-only)
- [ ] Real dealer, branches, users and role assignments created
- [ ] Chart of accounts reviewed against the dealer's actual books
- [ ] Document sequences configured for every document type and the current financial year
- [ ] Supabase Site URL and redirect URLs point at the production domain
- [ ] `SUPABASE_SERVICE_ROLE_KEY` set on Railway and nowhere client-side
- [ ] `APP_SECRET` is a fresh random value, not the example
- [ ] `/api/health` returns `configured: true`
- [ ] Point-in-time recovery enabled in Supabase — this is an accounting system

## Rollback

Railway keeps prior deployments; roll back from the dashboard. **Database migrations do not roll back
with it.** Each migration file documents its rollback in the header, but a migration that has already
accepted writes usually needs a forward fix rather than a reversal. Take a Supabase backup before
applying migrations to production.

## Troubleshooting

**Every route redirects to `/setup`.** `NEXT_PUBLIC_SUPABASE_URL` or the anon key is missing or
malformed. `/setup` names the offending variable. Note that `NEXT_PUBLIC_*` values are inlined at
build time — changing them on Railway requires a redeploy, not a restart.

**Signed in, but immediately signed out.** The user has no `public.user_profiles` row, or its status
is not `ACTIVE`.

**A page shows no rows where rows exist.** Usually correct behaviour: RLS is scoping to the caller's
dealer and branches, or the role lacks the view permission. Check `admin/roles` for what the role
actually grants.

**`permission denied for table …`** A grant is missing. Re-run `0011_grants.sql`.

**Health check fails on first deploy.** The build itself failed — check the Railway build log. The
health endpoint does not depend on Supabase.

## Cutting a dealer over from an existing system

Order matters, because each step depends on the one before it. Doing balances
before masters means party codes that resolve to nothing.

1. **Masters.** Customers → **Import Customers**, then Masters → **Import
   Suppliers**. Leave `customer_code` / `supplier_code` blank to have IDs issued,
   or fill them in to keep the ones the dealer already uses — worth doing when
   old invoices and paper records carry them, since renumbering makes every
   historical document unfindable by the number printed on it.
2. **Opening stock.** Vehicles → **Stock Upload** for chassis-level stock,
   Inventory → **Stock Upload** for accessories and spares.
3. **Opening balances.** Accounting → **Opening Balances**, once for customers
   and once for suppliers, dated to the day before trading starts here. Each
   upload posts one journal against 3300 Opening Balance Equity.
4. **Reconcile before going live:**
   - Trial balance balances, and 3300 equals the net of what was imported.
   - Per-party ledgers match the old system — spot-check the largest debtors and
     creditors rather than all of them.
   - Stock value on the inventory report matches the physical count.
5. **Clear 3300** into retained earnings once the figures are agreed. A non-zero
   3300 is a useful signal that the reconciliation is unfinished.

**Dry-run the whole sequence against a throwaway dealer first.** Provision one from
Administration → Dealers and run every step. `scripts/dry-run-cutover.sql` does exactly that
against a throwaway *database*, if you would rather rehearse without touching the live one.

**End the rehearsal by closing the tenant, not purging it.** `public.purge_dealer()` refuses once
anything is POSTED — a posted ledger is a statutory record — so once the rehearsal reaches opening
balances the only way out is `update public.dealers set status = 'CLOSED'`. Purge works only if you
stop before posting.

Two preconditions that are easy to miss, because both fail at the moment of onboarding:

- Provisioning is **platform-admin** work, and the incoming owner's **Supabase Auth account must
  already exist** — `provision_dealer` refuses to create a tenant nobody can sign into.
- A cut-over rehearsed once is a cut-over that does not have to be reversed in front of the dealer.
  The first run of the script above found three defects; none of them would have appeared in any
  unit test, because each was about the order things happen in.

If a step does go wrong: each import is one document. Reverse the journal
(Accounting → Journal Entries), fix the file, and upload again.
