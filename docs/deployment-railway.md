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

`seed.sql` is **required**: it installs the permission catalogue and the seven system roles, without
which nobody can be authorized for anything. It also creates a demo dealer; the teardown for that is
documented at the top of the file.

`seed-demo-ledger.sql` is optional and demo-only. It posts a month of balanced journals so the
dashboard shows real figures before the sales and inventory modules exist. Skip it in production.

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

- [ ] Migrations `0001`–`0012` applied
- [ ] `seed.sql` applied (permissions and system roles)
- [ ] `seed-demo-ledger.sql` **not** applied
- [ ] Demo dealer removed — `delete from public.dealers where code = 'SBM';` after its children
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
