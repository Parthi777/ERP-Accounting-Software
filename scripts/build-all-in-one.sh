#!/usr/bin/env bash
# =============================================================================
# build-all-in-one.sh — regenerate the pasteable schema bundles
# =============================================================================
# Concatenates every migration and seed, in order, into one transactional script
# for pasting into the Supabase SQL Editor. Run this after changing any migration
# or seed, or the bundles go stale — `npm run check:bundle` fails the build when
# they do.
#
# Two files are written, and the difference between them is the whole point:
#
#   ALL-IN-ONE.sql             schema + permission catalogue + system roles
#   ALL-IN-ONE-WITH-DEMO.sql   the above, plus the demo dealer and its trading data
#
# They were one file until the production bundle carried the demo dealer with a
# comment asking the operator to delete that section by hand before running it.
# For a file whose entire job is provisioning a tenant, a manual deletion step is
# the wrong safety model: it fails silently, and it fails towards a real dealer's
# database containing a fake dealer's ledger.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# -----------------------------------------------------------------------------
# emit <with-demo: yes|no>
# -----------------------------------------------------------------------------
# Writes a complete bundle to stdout. Both bundles share every migration and
# supabase/seed.sql; only the trailing demo section differs.
# -----------------------------------------------------------------------------
emit() {
  local with_demo="$1"

  cat <<'HDR'
-- =============================================================================
-- ALL-IN-ONE.sql — every migration and seed, concatenated in order
-- =============================================================================
-- GENERATED FILE. Do not edit; edit the sources and regenerate with
--   bash scripts/build-all-in-one.sh
--
-- For pasting into the Supabase SQL Editor in a single run instead of applying
-- the migrations one file at a time. Wrapped in one transaction: if any statement
-- fails, the whole thing rolls back and the database is left untouched — you will
-- never end up with a half-applied schema.
--
-- Run once, on an empty project. Re-running fails on the first CREATE TABLE,
-- which is the intended signal that there is nothing to do.
HDR

  if [ "$with_demo" = "yes" ]; then
    cat <<'HDR'
--
-- ─────────────────────────────────────────────────────────────────────────────
-- THIS BUNDLE INCLUDES THE DEMO DEALER AND ITS TRADING DATA.
--
-- It is for evaluation, screenshots and local work. Do not run it against a
-- database that will hold a real dealer — use ALL-IN-ONE.sql instead, which is
-- the same schema with no demo rows. If you have already run this one, remove
-- the demo tenant with scripts/remove-demo-dealer.sql, which takes the demo
-- dealer and everything under it while keeping the permission catalogue, the
-- system roles and the audit trail.
-- ─────────────────────────────────────────────────────────────────────────────
HDR
  else
    cat <<'HDR'
--
-- This is the production bundle: schema, permission catalogue and system roles,
-- and no demo data. For an evaluation database that comes with a dealer, three
-- branches and a populated ledger, use ALL-IN-ONE-WITH-DEMO.sql.
HDR
  fi

  printf -- '-- =============================================================================\n\nbegin;\n\n'

  for f in "$ROOT_DIR"/supabase/migrations/*.sql; do
    printf '\n\n-- ═══════════════════════════════════════════════════════════════════════════\n-- SOURCE: supabase/migrations/%s\n-- ═══════════════════════════════════════════════════════════════════════════\n\n' "$(basename "$f")"
    cat "$f"
  done

  # The demo data lives in scripts/ rather than supabase/ because it is a tool,
  # not part of the schema. Backslash lines are psql meta-commands (\set and the
  # like) — they are valid when the file is run through psql, and a syntax error
  # in the Supabase SQL Editor, which this bundle is written for. Strip them.
  # supabase/seed.sql holds both kinds of data: the REQUIRED permission catalogue
  # and system roles, and then a demo tenant. The production bundle takes only
  # the first part, cut at the @BUNDLE-CUT marker in that file — without this the
  # "production" bundle still seeds a fake dealer with three branches and seven
  # users, which is most of what splitting the bundles was for.
  printf '\n\n-- ═══════════════════════════════════════════════════════════════════════════\n-- SOURCE: supabase/seed.sql%s\n-- ═══════════════════════════════════════════════════════════════════════════\n\n' \
    "$([ "$with_demo" = yes ] && echo '' || echo ' (required sections only)')"

  if [ "$with_demo" = "yes" ]; then
    grep -v '^\\' "$ROOT_DIR/supabase/seed.sql"
  else
    if ! grep -q '^-- @BUNDLE-CUT' "$ROOT_DIR/supabase/seed.sql"; then
      echo "build-all-in-one.sh: @BUNDLE-CUT marker missing from supabase/seed.sql" >&2
      exit 1
    fi
    sed '/^-- @BUNDLE-CUT/,$d' "$ROOT_DIR/supabase/seed.sql" | grep -v '^\\'
  fi

  if [ "$with_demo" = "yes" ]; then
    printf '\n\n-- ═══════════════════════════════════════════════════════════════════════════\n-- SOURCE: scripts/seed-demo-data.sql\n-- ═══════════════════════════════════════════════════════════════════════════\n\n'
    grep -v '^\\' "$ROOT_DIR/scripts/seed-demo-data.sql"
  fi

  printf '\n\ncommit;\n'
}

report() {
  printf 'wrote %s (%s, %s lines)\n' "$1" "$(du -h "$1" | cut -f1)" "$(wc -l < "$1" | tr -d ' ')"
}

PLAIN="$ROOT_DIR/supabase/ALL-IN-ONE.sql"
DEMO="$ROOT_DIR/supabase/ALL-IN-ONE-WITH-DEMO.sql"

emit no  > "$PLAIN"
emit yes > "$DEMO"

report "$PLAIN"
report "$DEMO"
