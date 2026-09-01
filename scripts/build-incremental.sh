#!/usr/bin/env bash
# =============================================================================
# build-incremental.sh — bundle a range of migrations into one runnable file
# =============================================================================
# For a database that already has the earlier migrations. Re-running the full
# ALL-IN-ONE.sql there would fail on the first CREATE TABLE that already exists,
# so this bundles only what is missing.
#
#   FROM=0013 bash scripts/build-incremental.sh            # 0013 → latest
#   FROM=0013 TO=0020 bash scripts/build-incremental.sh    # a closed range
#   FROM=0013 WITH_SEED=1 bash scripts/build-incremental.sh
#
# The output is wrapped in a single transaction: if any statement fails, nothing
# is applied and the database is exactly as it was.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FROM="${FROM:?Set FROM to the first migration number, e.g. FROM=0013}"
TO="${TO:-9999}"

shopt -s nullglob
FILES=()
for f in "$ROOT_DIR"/supabase/migrations/*.sql; do
  n="$(basename "$f" | cut -d_ -f1)"
  if [[ "$n" > "$FROM" || "$n" == "$FROM" ]] && [[ "$n" < "$TO" || "$n" == "$TO" ]]; then
    FILES+=("$f")
  fi
done

if [ ${#FILES[@]} -eq 0 ]; then
  echo "No migrations in range $FROM..$TO" >&2
  exit 1
fi

LAST="$(basename "${FILES[${#FILES[@]}-1]}" | cut -d_ -f1)"
OUT="$ROOT_DIR/supabase/INCREMENTAL-${FROM}-to-${LAST}.sql"

{
  cat <<HDR
-- =============================================================================
-- INCREMENTAL ${FROM} → ${LAST}
-- =============================================================================
-- GENERATED FILE. Regenerate with:
--   FROM=${FROM} bash scripts/build-incremental.sh
--
-- For a database that ALREADY has migrations up to $(printf '%04d' $((10#$FROM - 1))).
-- Running the full ALL-IN-ONE.sql on such a database fails on the first table
-- that already exists; this contains only what is missing.
--
-- Wrapped in one transaction. If any statement fails the whole thing rolls back
-- and the database is left exactly as it was — there is no half-applied state to
-- clean up, and it is safe to fix the cause and run again.
--
-- Paste into the Supabase SQL Editor and Run.
-- =============================================================================

begin;

HDR

  for f in "${FILES[@]}"; do
    printf '\n\n-- ═══════════════════════════════════════════════════════════════════════════\n-- SOURCE: supabase/migrations/%s\n-- ═══════════════════════════════════════════════════════════════════════════\n\n' "$(basename "$f")"
    cat "$f"
  done

  if [ "${WITH_SEED:-0}" = "1" ]; then
    printf '\n\n-- ═══════════════════════════════════════════════════════════════════════════\n-- SOURCE: supabase/seed.sql (idempotent)\n-- ═══════════════════════════════════════════════════════════════════════════\n\n'
    cat "$ROOT_DIR/supabase/seed.sql"
  fi

  printf '\n\ncommit;\n'
} > "$OUT"

printf 'wrote %s\n' "$OUT"
printf '  %d migration(s): %s → %s\n' "${#FILES[@]}" "$FROM" "$LAST"
printf '  %s, %s lines\n' "$(du -h "$OUT" | cut -f1)" "$(wc -l < "$OUT" | tr -d ' ')"
