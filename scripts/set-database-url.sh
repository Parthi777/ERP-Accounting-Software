#!/usr/bin/env bash
# =============================================================================
# set-database-url.sh — put a working DATABASE_URL into .env.local
# =============================================================================
# The database password is not recoverable once lost: Supabase stores a hash, so
# there is no screen that shows it to you again. Resetting it is the only way
# back, and the reset invalidates the old one everywhere it is configured —
# including Railway. That is why this script tests before it writes.
#
#   1. Supabase → Project Settings → Database → Reset database password
#   2. bash scripts/set-database-url.sh        (paste when prompted)
#
# The password is read with the terminal echo off, is never printed, and never
# reaches the shell history or the process list. .env.local is only modified
# after a real connection has succeeded, so a wrong paste leaves you exactly
# where you were rather than swapping one broken URL for another.
#
# Non-interactive:  SUPABASE_DB_PASSWORD='...' bash scripts/set-database-url.sh
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env.local"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
blue()  { printf '\033[34m%s\033[0m\n' "$*"; }

[ -f "$ENV_FILE" ] || { red "No .env.local — copy .env.example first."; exit 1; }
command -v psql >/dev/null 2>&1 || { red "psql not found. brew install postgresql@16"; exit 1; }

# ── Work out the project from what is already configured ─────────────────────
# Taken from NEXT_PUBLIC_SUPABASE_URL rather than the old DATABASE_URL, so this
# still works when the DATABASE_URL line is missing or malformed.
API_URL="$(grep -E '^NEXT_PUBLIC_SUPABASE_URL=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '"'\''' | tr -d '[:space:]')"
REF="$(printf '%s' "$API_URL" | sed -E 's#^https://([a-z0-9]+)\.supabase\.co/?$#\1#')"

if [ -z "$REF" ] || [ "$REF" = "$API_URL" ]; then
  red "Could not read the project ref from NEXT_PUBLIC_SUPABASE_URL."
  exit 1
fi

# Keep whatever pooler host is already configured; the region is part of it and
# guessing it wrong produces a confusing DNS failure rather than a clear one.
OLD="$(grep -E '^DATABASE_URL=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '"'\''' || true)"
HOST="$(printf '%s' "$OLD" | sed -nE 's#.*@([^:/]+).*#\1#p')"
PORT="$(printf '%s' "$OLD" | sed -nE 's#.*@[^:]+:([0-9]+).*#\1#p')"
HOST="${HOST:-aws-0-ap-south-1.pooler.supabase.com}"
PORT="${PORT:-5432}"

blue "Project ${REF} · ${HOST}:${PORT}"
echo

if [ -n "${SUPABASE_DB_PASSWORD:-}" ]; then
  PW="$SUPABASE_DB_PASSWORD"
else
  printf 'Database password (Project Settings → Database): '
  stty -echo 2>/dev/null || true
  IFS= read -r PW
  stty echo 2>/dev/null || true
  echo
fi

[ -n "$PW" ] || { red "No password entered."; exit 1; }

# ── Test before writing ──────────────────────────────────────────────────────
blue "==> Testing the connection"
if ! OUT=$(PGPASSWORD="$PW" psql --no-psqlrc -tA \
            -h "$HOST" -p "$PORT" -U "postgres.${REF}" -d postgres \
            -c 'select 1' 2>&1); then
  red "Connection failed. .env.local has NOT been changed."
  printf '  %s\n' "$(printf '%s' "$OUT" | head -1)"
  echo
  echo "  If it says password authentication failed, reset the password at"
  echo "  Supabase → Project Settings → Database, and remember to update it on"
  echo "  Railway too — the reset invalidates the old one everywhere."
  exit 1
fi
green "    connected"

# What the database says about itself, which is the reason to have psql at all.
VERSION=$(PGPASSWORD="$PW" psql --no-psqlrc -tA -h "$HOST" -p "$PORT" \
            -U "postgres.${REF}" -d postgres \
            -c "select coalesce(max(version), 'not recorded') from public.schema_migrations" 2>/dev/null || echo 'no schema_migrations table')
blue "==> Schema version: ${VERSION}"

# ── Write, keeping a backup ──────────────────────────────────────────────────
# .gitignore already covers .env*.bak, so the copy cannot be committed.
URL="postgresql://postgres.${REF}:$(printf '%s' "$PW" | sed -e 's/[\/&:@?#%]/\\&/g')@${HOST}:${PORT}/postgres"
cp "$ENV_FILE" "$ENV_FILE.bak"

if grep -qE '^DATABASE_URL=' "$ENV_FILE"; then
  awk -v url="DATABASE_URL=$URL" '/^DATABASE_URL=/ { print url; next } { print }' \
    "$ENV_FILE" > "$ENV_FILE.tmp"
else
  cp "$ENV_FILE" "$ENV_FILE.tmp"
  printf '\nDATABASE_URL=%s\n' "$URL" >> "$ENV_FILE.tmp"
fi
mv "$ENV_FILE.tmp" "$ENV_FILE"

green "==> .env.local updated (previous copy at .env.local.bak)"
echo
echo "  Now you can run:"
echo "    psql \"\$DATABASE_URL\" -f scripts/post-migration-check.sql"
echo "    FROM=00NN npm run db:incremental && psql \"\$DATABASE_URL\" -f supabase/INCREMENTAL-*.sql"
echo
echo "  If you reset the password, update it on Railway as well."
