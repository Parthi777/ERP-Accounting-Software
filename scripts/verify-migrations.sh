#!/usr/bin/env bash
# =============================================================================
# verify-migrations.sh — apply every migration to a throwaway local database
# =============================================================================
# Creates a fresh database, loads the Supabase shim, applies the migrations in
# order, applies the seeds, runs the RLS and accounting integrity tests, then
# drops the database again.
#
# Existing databases are never touched. Requires a local PostgreSQL 15+ server.
#
#   bash scripts/verify-migrations.sh          # verify and drop
#   KEEP_DB=1 bash scripts/verify-migrations.sh  # verify and leave it for inspection
# =============================================================================
set -euo pipefail

DB_NAME="${DB_NAME:-twerp_migration_check}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PSQL_BASE=(psql --no-psqlrc --quiet -v ON_ERROR_STOP=1)

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
blue()  { printf '\033[34m%s\033[0m\n' "$*"; }

if ! command -v psql >/dev/null 2>&1; then
  red "psql not found. Install PostgreSQL 15+ or run the migrations against Supabase instead."
  exit 1
fi

if ! pg_isready -q; then
  red "No PostgreSQL server is accepting connections."
  exit 1
fi

SERVER_VERSION="$("${PSQL_BASE[@]}" -d postgres -tAc 'show server_version_num')"
if [ "$SERVER_VERSION" -lt 150000 ]; then
  red "PostgreSQL 15+ required (UNIQUE NULLS NOT DISTINCT). Found server_version_num=$SERVER_VERSION."
  exit 1
fi

cleanup() {
  if [ "${KEEP_DB:-0}" != "1" ]; then
    "${PSQL_BASE[@]}" -d postgres -c "drop database if exists \"$DB_NAME\" with (force)" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

blue "==> Creating throwaway database: $DB_NAME"
"${PSQL_BASE[@]}" -d postgres -c "drop database if exists \"$DB_NAME\" with (force)" >/dev/null
"${PSQL_BASE[@]}" -d postgres -c "create database \"$DB_NAME\"" >/dev/null

run_sql() {
  local label="$1" file="$2"
  printf '    %-42s' "$label"
  if OUT=$("${PSQL_BASE[@]}" -d "$DB_NAME" -f "$file" 2>&1); then
    green "ok"
    # Surface test NOTICEs from the assertion helpers.
    echo "$OUT" | grep -E '^(NOTICE|psql:.*NOTICE)' | sed 's/^NOTICE:[[:space:]]*/      /' || true
  else
    red "FAILED"
    echo "$OUT" | sed 's/^/      /'
    exit 1
  fi
}

blue "==> Loading Supabase shim (local only)"
run_sql "00_supabase_shim.sql" "$ROOT_DIR/supabase/test/00_supabase_shim.sql"

blue "==> Applying migrations"
shopt -s nullglob
MIGRATIONS=("$ROOT_DIR"/supabase/migrations/*.sql)
if [ ${#MIGRATIONS[@]} -eq 0 ]; then
  red "No migrations found in supabase/migrations/"
  exit 1
fi
for f in "${MIGRATIONS[@]}"; do
  run_sql "$(basename "$f")" "$f"
done

blue "==> Applying seeds"
run_sql "seed.sql" "$ROOT_DIR/supabase/seed.sql"

# scripts/seed-demo-data.sql is deliberately NOT loaded here. It consumes document
# numbers and creates stock of its own, which the integrity tests below assert
# against. Its own correctness is checked by running it against a database seeded
# this way; see the header of that file.

blue "==> Running integrity tests"
for f in "$ROOT_DIR"/supabase/test/[1-9]*.sql; do
  run_sql "$(basename "$f")" "$f"
done

blue "==> Schema summary"
"${PSQL_BASE[@]}" -d "$DB_NAME" -tAc "
  select '    tables:      ' || count(*) from pg_tables where schemaname = 'public'
  union all
  select '    policies:    ' || count(*) from pg_policies where schemaname = 'public'
  union all
  select '    indexes:     ' || count(*) from pg_indexes where schemaname = 'public'
  union all
  select '    constraints: ' || count(*) from pg_constraint c
    join pg_class t on t.oid = c.conrelid
    join pg_namespace n on n.oid = t.relnamespace
   where n.nspname = 'public'
  union all
  select '    triggers:    ' || count(*) from pg_trigger where not tgisinternal
"

# Every table carrying tenant data must have RLS on. Catches a new table added
# without policies, which is the realistic way isolation gets broken later.
blue "==> Checking every public table has RLS enabled"
UNPROTECTED="$("${PSQL_BASE[@]}" -d "$DB_NAME" -tAc "
  select string_agg(c.relname, ', ' order by c.relname)
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity
")"
if [ -n "$UNPROTECTED" ]; then
  red "    Tables without RLS: $UNPROTECTED"
  exit 1
fi
green "    all tables protected"

echo
green "All migrations, seeds and integrity tests passed."
if [ "${KEEP_DB:-0}" = "1" ]; then
  blue "Database kept: psql $DB_NAME"
fi
