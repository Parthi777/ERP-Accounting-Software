#!/usr/bin/env bash
# =============================================================================
# build-all-in-one.sh — regenerate supabase/ALL-IN-ONE.sql
# =============================================================================
# Concatenates every migration and seed, in order, into one transactional script
# for pasting into the Supabase SQL Editor. Run this after changing any migration
# or seed, or the combined file goes stale.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT_DIR/supabase/ALL-IN-ONE.sql"

{
  cat <<'HDR'
-- =============================================================================
-- ALL-IN-ONE.sql — every migration and seed, concatenated in order
-- =============================================================================
-- GENERATED FILE. Do not edit; edit the sources and regenerate with
--   bash scripts/build-all-in-one.sh
--
-- For pasting into the Supabase SQL Editor in a single run instead of applying
-- fourteen files by hand. Wrapped in one transaction: if any statement fails,
-- the whole thing rolls back and the database is left untouched — you will never
-- end up with a half-applied schema.
--
-- Run once, on an empty project. Re-running fails on the first CREATE TABLE,
-- which is the intended signal that there is nothing to do.
--
-- Includes the demo ledger. For a production database, delete the
-- seed-demo-ledger.sql section at the end before running.
-- =============================================================================

begin;

HDR

  for f in "$ROOT_DIR"/supabase/migrations/*.sql; do
    printf '\n\n-- ═══════════════════════════════════════════════════════════════════════════\n-- SOURCE: supabase/migrations/%s\n-- ═══════════════════════════════════════════════════════════════════════════\n\n' "$(basename "$f")"
    cat "$f"
  done

  for f in seed.sql seed-demo-ledger.sql; do
    printf '\n\n-- ═══════════════════════════════════════════════════════════════════════════\n-- SOURCE: supabase/%s\n-- ═══════════════════════════════════════════════════════════════════════════\n\n' "$f"
    cat "$ROOT_DIR/supabase/$f"
  done

  printf '\n\ncommit;\n'
} > "$OUT"

printf 'wrote %s (%s, %s lines)\n' "$OUT" "$(du -h "$OUT" | cut -f1)" "$(wc -l < "$OUT" | tr -d ' ')"
