#!/usr/bin/env bash
# =============================================================================
# restore-drill.sh — prove the production database can be restored, whole
# =============================================================================
# A backup nobody has restored is a hope. This takes a logical backup of the
# production database (read-only), restores it into a throwaway local database,
# and compares the two: row counts for every table, the schema version, and per
# dealer a checksum of every journal line and of the trial balance. It reports
# how long the dump and the restore took — the restore time is the RTO you can
# actually claim for a logical restore.
#
# The restore runs in sections — tables, then data, then any repairs a pending
# migration will make (scripts/drill-repairs.sql), then constraints and
# indexes — so a row the live database tolerates but a restore would refuse is
# reported by name rather than as a failed restore halfway through.
#
# It never writes to the source: the session is forced read-only
# (default_transaction_read_only), and pg_dump only reads. The dump holds
# customer data, so it is written to a private temporary directory and deleted
# at the end with the restored database, unless KEEP_DRILL=1.
#
#   bash scripts/restore-drill.sh                   # DATABASE_URL from env or .env.local
#   DRILL_SOURCE_URL=postgres://… bash scripts/restore-drill.sh
#   KEEP_DRILL=1 bash scripts/restore-drill.sh      # keep the dump and the database
#
# Requires: a local PostgreSQL server (15+) and a pg_dump at least as new as the
# source server (Homebrew: postgresql@17). See docs/backup-restore-runbook.md.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DB_NAME="${DRILL_DB:-twerp_restore_drill}"
LOCAL=(psql --no-psqlrc --quiet -v ON_ERROR_STOP=1)

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
blue()  { printf '\033[34m%s\033[0m\n' "$*"; }

SOURCE_URL="${DRILL_SOURCE_URL:-${DATABASE_URL:-}}"
if [ -z "$SOURCE_URL" ] && [ -f "$ROOT_DIR/.env.local" ]; then
  SOURCE_URL="$(grep -E '^DATABASE_URL=' "$ROOT_DIR/.env.local" | head -1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//')"
fi
if [ -z "$SOURCE_URL" ]; then
  red "No source database. Set DRILL_SOURCE_URL or DATABASE_URL (the session pooler, port 5432)."
  exit 1
fi

# Every connection to the source is read-only, whatever runs on it.
SRC() { PGOPTIONS='-c default_transaction_read_only=on' "$@"; }

if ! pg_isready -q; then
  red "No local PostgreSQL server is accepting connections."
  exit 1
fi

# ── A pg_dump at least as new as the source ────────────────────────────────
SOURCE_NUM="$(SRC psql "$SOURCE_URL" --no-psqlrc -tAc 'show server_version_num')"
SOURCE_MAJOR=$((SOURCE_NUM / 10000))
PG_DUMP=""
for candidate in "$(command -v pg_dump || true)" \
                 /opt/homebrew/opt/postgresql@{18,17,16,15}/bin/pg_dump \
                 /usr/local/opt/postgresql@{18,17,16,15}/bin/pg_dump \
                 /usr/lib/postgresql/{18,17,16,15}/bin/pg_dump; do
  [ -x "$candidate" ] || continue
  major="$("$candidate" --version | sed -E 's/.* ([0-9]+)\..*/\1/')"
  if [ "$major" -ge "$SOURCE_MAJOR" ]; then PG_DUMP="$candidate"; break; fi
done
if [ -z "$PG_DUMP" ]; then
  red "Need pg_dump $SOURCE_MAJOR or newer for a PostgreSQL $SOURCE_MAJOR source (brew install postgresql@$SOURCE_MAJOR)."
  exit 1
fi

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/twerp-drill.XXXXXX")"
chmod 700 "$WORK_DIR"
cleanup() {
  if [ "${KEEP_DRILL:-0}" != "1" ]; then
    "${LOCAL[@]}" -d postgres -c "drop database if exists \"$DB_NAME\" with (force)" >/dev/null 2>&1 || true
    rm -rf "$WORK_DIR"
  else
    blue "Kept: database $DB_NAME and $WORK_DIR (holds customer data — delete when done)."
  fi
}
trap cleanup EXIT

now() { date +%s; }

blue "==> Source: PostgreSQL $SOURCE_MAJOR · dumping with $PG_DUMP"
t0=$(now)
SRC "$PG_DUMP" "$SOURCE_URL" --format=custom --no-owner --no-privileges \
  --schema=public --schema=app --file="$WORK_DIR/dump.pgc"
# auth.users is Supabase's; only the columns the ERP references are carried.
SRC psql "$SOURCE_URL" --no-psqlrc -q \
  -c "\\copy (select id, email, created_at from auth.users order by id) to '$WORK_DIR/auth_users.csv' csv"
SRC psql "$SOURCE_URL" --no-psqlrc -q -f "$ROOT_DIR/scripts/drill-fingerprint.sql" > "$WORK_DIR/source.txt"
t1=$(now)
DUMP_SIZE="$(du -h "$WORK_DIR/dump.pgc" | cut -f1)"
green "    dump ${DUMP_SIZE} in $((t1 - t0))s"

ORPHANS="$(SRC psql "$SOURCE_URL" --no-psqlrc -q -f "$ROOT_DIR/scripts/drill-orphans.sql" 2>&1 | grep -o 'orphans .*' || true)"
if [ -n "$ORPHANS" ]; then
  red "    The source holds rows whose foreign key points at nothing; a restore refuses them:"
  echo "$ORPHANS" | sed 's/^orphans /      /'
  blue "    Restoring with scripts/drill-repairs.sql applied — the source needs the same repair."
fi

blue "==> Restoring into local database $DB_NAME"
"${LOCAL[@]}" -d postgres -c "drop database if exists \"$DB_NAME\" with (force)" >/dev/null 2>&1
"${LOCAL[@]}" -d postgres -c "create database \"$DB_NAME\"" >/dev/null
"${LOCAL[@]}" -d "$DB_NAME" -f "$ROOT_DIR/supabase/test/00_supabase_shim.sql" >/dev/null
"${LOCAL[@]}" -d "$DB_NAME" -c "\\copy auth.users (id, email, created_at) from '$WORK_DIR/auth_users.csv' csv"
# Each section as SQL, less the settings a newer pg_dump writes that an older
# server does not know.
PG_RESTORE="$(dirname "$PG_DUMP")/pg_restore"
restore_section() {
  local section="$1"
  "$PG_RESTORE" --no-owner --no-privileges --section="$section" -f - "$WORK_DIR/dump.pgc" \
    | sed -E -e '/^SET (transaction_timeout|default_table_access_method)/d' \
             -e '/^CREATE SCHEMA public;$/d' > "$WORK_DIR/$section.sql"
  if ! "${LOCAL[@]}" -d "$DB_NAME" -f "$WORK_DIR/$section.sql" > "$WORK_DIR/$section.log" 2>&1; then
    red "    restore FAILED in $section:"
    grep -E 'ERROR|DETAIL' "$WORK_DIR/$section.log" | head -10 | sed 's/^/      /'
    exit 1
  fi
}
restore_section pre-data
restore_section data
"${LOCAL[@]}" -d "$DB_NAME" -f "$ROOT_DIR/scripts/drill-repairs.sql" > /dev/null
restore_section post-data
"${LOCAL[@]}" -d "$DB_NAME" -f "$ROOT_DIR/scripts/drill-grants.sql" > /dev/null
t2=$(now)
green "    restored in $((t2 - t1))s"

blue "==> Comparing source and restore"
"${LOCAL[@]}" -d "$DB_NAME" -f "$ROOT_DIR/scripts/drill-fingerprint.sql" > "$WORK_DIR/restored.txt"
if diff -u "$WORK_DIR/source.txt" "$WORK_DIR/restored.txt" > "$WORK_DIR/diff.txt"; then
  green "    identical: $(grep -c '^rows ' "$WORK_DIR/source.txt") tables, every row count, ledger and trial-balance checksum"
else
  red "    DIFFERENT — the restore is not a faithful copy:"
  sed 's/^/      /' "$WORK_DIR/diff.txt" | head -40
  exit 1
fi

grep -E '^(schema_version|ledger|trial_balance|stock) ' "$WORK_DIR/source.txt" | sed 's/^/    /'
if grep -E '^trial_balance ' "$WORK_DIR/source.txt" | grep -vqE '\| 0(\.0+)? \(must be 0\)$'; then
  red "    A dealer's trial balance does not net to zero in the source itself."
  exit 1
fi

green "Restore drill passed on $(date '+%Y-%m-%d %H:%M'): dump $((t1 - t0))s, restore $((t2 - t1))s, total $((t2 - t0))s."
