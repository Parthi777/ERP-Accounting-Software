#!/usr/bin/env bash
# =============================================================================
# apply-to-supabase.sh — apply every migration and seed to a live database
# =============================================================================
# Applies supabase/migrations/*.sql in order, then seed.sql, against the database
# named by DATABASE_URL. Stops at the first error rather than leaving the schema
# half-applied.
#
#   DATABASE_URL='postgresql://...' bash scripts/apply-to-supabase.sh
#   DATABASE_URL='postgresql://...' WITH_DEMO=1 bash scripts/apply-to-supabase.sh
#
# WITH_DEMO=1 also loads seed-demo-ledger.sql, which posts a month of balanced
# demo journals so the dashboard has figures. Leave it off for production.
#
# Safe to re-run: seed.sql is idempotent, and the demo ledger skips itself if it
# has already been applied. The migrations are NOT idempotent — re-running them
# against a database that already has the schema will fail on the first CREATE
# TABLE, which is the intended signal that there is nothing to do.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
blue()  { printf '\033[34m%s\033[0m\n' "$*"; }

if [ -z "${DATABASE_URL:-}" ]; then
  red "DATABASE_URL is not set."
  echo
  echo "  Supabase dashboard → Project Settings → Database → Connection string → URI"
  echo "  Then:  DATABASE_URL='postgresql://...' bash scripts/apply-to-supabase.sh"
  exit 1
fi

if ! command -v psql >/dev/null 2>&1; then
  red "psql not found. Install the PostgreSQL client, or paste the files into the Supabase SQL editor."
  exit 1
fi

PSQL=(psql "$DATABASE_URL" --no-psqlrc --quiet -v ON_ERROR_STOP=1)

blue "==> Checking connection"
if ! SERVER_VERSION="$("${PSQL[@]}" -tAc 'show server_version_num' 2>/dev/null)"; then
  red "Could not connect. Check the URL, the password, and that your IP is allowed."
  exit 1
fi
green "    connected (server_version_num=$SERVER_VERSION)"

if [ "$SERVER_VERSION" -lt 150000 ]; then
  red "PostgreSQL 15+ required (UNIQUE NULLS NOT DISTINCT)."
  exit 1
fi

# Refuse to run over an existing install rather than failing halfway through it.
EXISTING="$("${PSQL[@]}" -tAc "select count(*) from pg_tables where schemaname = 'public' and tablename = 'dealers'")"
if [ "$EXISTING" != "0" ] && [ "${FORCE:-0}" != "1" ]; then
  red "This database already has a 'dealers' table — the schema looks applied."
  echo "  To re-seed only:   psql \"\$DATABASE_URL\" -f supabase/seed.sql"
  echo "  To proceed anyway: FORCE=1 bash scripts/apply-to-supabase.sh"
  exit 1
fi

run_sql() {
  local label="$1" file="$2"
  printf '    %-42s' "$label"
  if OUT=$("${PSQL[@]}" -f "$file" 2>&1); then
    green "ok"
    echo "$OUT" | grep -E '^NOTICE' | sed 's/^NOTICE:[[:space:]]*/      /' || true
  else
    red "FAILED"
    echo "$OUT" | sed 's/^/      /'
    echo
    red "Stopped. Nothing after this file was applied."
    exit 1
  fi
}

blue "==> Applying migrations"
shopt -s nullglob
for f in "$ROOT_DIR"/supabase/migrations/*.sql; do
  run_sql "$(basename "$f")" "$f"
done

blue "==> Seeding permissions, roles and the demo dealer"
run_sql "seed.sql" "$ROOT_DIR/supabase/seed.sql"

if [ "${WITH_DEMO:-0}" = "1" ]; then
  blue "==> Seeding the demo ledger (dashboard figures)"
  run_sql "seed-demo-ledger.sql" "$ROOT_DIR/supabase/seed-demo-ledger.sql"
fi

blue "==> Summary"
"${PSQL[@]}" -tAc "
  select '    tables:      ' || count(*) from pg_tables where schemaname = 'public'
  union all
  select '    policies:    ' || count(*) from pg_policies where schemaname = 'public'
  union all
  select '    permissions: ' || count(*) from public.permissions
  union all
  select '    roles:       ' || count(*) from public.roles
  union all
  select '    journals:    ' || count(*) from public.journal_entries where status = 'POSTED'
"

UNPROTECTED="$("${PSQL[@]}" -tAc "
  select coalesce(string_agg(c.relname, ', ' order by c.relname), '')
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity
")"
if [ -n "$UNPROTECTED" ]; then
  red "    Tables without RLS: $UNPROTECTED"
  exit 1
fi
green "    every table has row level security enabled"

echo
green "Schema applied."
echo
echo "  Next: create the login users in Supabase Auth. The seeded profiles expect"
echo "  these addresses (password is yours to choose):"
echo "    owner@sribalajimotors.example      Dealer Owner   — all branches, all financials"
echo "    accounts@sribalajimotors.example   Accounts       — cost and margin visible"
echo "    cashier@sribalajimotors.example    Cashier        — no cost or margin"
echo
echo "  Their user ids must match the seeded profiles. See scripts/link-auth-users.sql."
