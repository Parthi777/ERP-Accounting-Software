#!/usr/bin/env bash
# =============================================================================
# generate-types.sh — rebuild src/types/database.types.ts from the migrations
# =============================================================================
# Applies every migration to a throwaway database, introspects it, and writes the
# TypeScript types. Run after changing any migration.
#
# The types are generated rather than hand-written because a hand-written copy
# drifts silently, and the failure mode is a query that compiles and returns
# nothing.
# =============================================================================
set -euo pipefail

DB="${DB:-twerp_typegen}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PSQL=(psql --no-psqlrc --quiet -v ON_ERROR_STOP=1)

cleanup() {
  "${PSQL[@]}" -d postgres -c "drop database if exists \"$DB\" with (force)" >/dev/null 2>&1 || true
}
trap cleanup EXIT

"${PSQL[@]}" -d postgres -c "drop database if exists \"$DB\" with (force)" >/dev/null
"${PSQL[@]}" -d postgres -c "create database \"$DB\"" >/dev/null

"${PSQL[@]}" -d "$DB" -f "$ROOT/supabase/test/00_supabase_shim.sql" >/dev/null

for f in "$ROOT"/supabase/migrations/*.sql; do
  if ! OUT=$("${PSQL[@]}" -d "$DB" -f "$f" 2>&1); then
    printf '\033[31mFAILED: %s\033[0m\n' "$(basename "$f")"
    echo "$OUT" | tail -10
    exit 1
  fi
done

DB="$DB" node "$ROOT/scripts/generate-types.mjs"
