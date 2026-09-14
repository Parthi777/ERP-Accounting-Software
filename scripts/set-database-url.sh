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

# A password pasted from a browser very often arrives with a trailing space or
# newline, and Postgres treats those as part of it — which fails identically to
# a genuinely wrong password and is invisible on screen.
PW_RAW="$PW"
PW="$(printf '%s' "$PW" | tr -d '\r\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"

[ -n "$PW" ] || { red "No password entered."; exit 1; }

if [ "$PW" != "$PW_RAW" ]; then
  blue "==> Trimmed surrounding whitespace from the pasted password"
fi
printf '    password: %d characters\n' "${#PW}"

# ── Find a route that actually authenticates ─────────────────────────────────
#
# There is more than one way into a Supabase database and which one works is not
# a matter of taste:
#
#   direct   db.<ref>.supabase.co:5432 as `postgres`
#            IPv6-only since Supabase moved direct connections off IPv4. Fine
#            from a machine with IPv6; unreachable from one without, and the
#            IPv4 add-on is the paid way round that.
#
#   pooler   aws-N-<region>.pooler.supabase.com as `postgres.<ref>`
#            IPv4, and the username *must* carry the project ref. There are two
#            generations, aws-0 and aws-1, and a project lives on exactly one of
#            them. Connecting to the wrong generation with a perfectly good
#            password fails as "password authentication failed", because that
#            pooler has never heard of the tenant — which is why this script
#            tries rather than assumes.
#
# 5432 is session mode, 6543 transaction mode. Both authenticate the same way;
# transaction mode is the one to use from a serverless host.
CANDIDATES=(
  "db.${REF}.supabase.co|5432|postgres|direct (IPv6 only)"
  "aws-0-ap-south-1.pooler.supabase.com|5432|postgres.${REF}|pooler aws-0, session"
  "aws-0-ap-south-1.pooler.supabase.com|6543|postgres.${REF}|pooler aws-0, transaction"
  "aws-1-ap-south-1.pooler.supabase.com|5432|postgres.${REF}|pooler aws-1, session"
  "aws-1-ap-south-1.pooler.supabase.com|6543|postgres.${REF}|pooler aws-1, transaction"
)

# Whatever is already configured goes first: if it works, nothing moves.
if [ -n "$HOST" ]; then
  CANDIDATES=("${HOST}|${PORT}|postgres.${REF}|currently configured" "${CANDIDATES[@]}")
fi

blue "==> Trying each route"
FOUND_HOST=""; FOUND_PORT=""; FOUND_USER=""

for entry in "${CANDIDATES[@]}"; do
  IFS='|' read -r c_host c_port c_user c_label <<< "$entry"
  printf '    %-34s ' "$c_label"

  # Without a timeout a route with no network path hangs for the OS default,
  # and there are five of them to get through.
  if OUT=$(PGCONNECT_TIMEOUT=8 PGPASSWORD="$PW" psql --no-psqlrc -tA \
            -h "$c_host" -p "$c_port" -U "$c_user" -d postgres \
            -c 'select 1' 2>&1); then
    green "connected"
    FOUND_HOST="$c_host"; FOUND_PORT="$c_port"; FOUND_USER="$c_user"
    break
  fi

  # The distinction matters: a refused password is a different problem from a
  # host that cannot be reached, and saying which saves a round of guessing.
  case "$OUT" in
    *"password authentication failed"*) echo "password refused" ;;
    *"could not translate"*|*"Network is unreachable"*|*"No route to host"*) echo "unreachable from here" ;;
    *"timeout"*|*"timed out"*)          echo "timed out" ;;
    *"Tenant or user not found"*)       echo "wrong pooler for this project" ;;
    *"Connection refused"*)             echo "port closed" ;;
    *)
      # Prefer the server's own FATAL text; fall back to the first line, with
      # the psql preamble and the host echo stripped so the reason is visible.
      MSG=$(printf '%s' "$OUT" | sed -nE 's/.*FATAL: *(.*)/\1/p' | head -1)
      [ -n "$MSG" ] || MSG=$(printf '%s' "$OUT" | tr '\n' ' ' \
                             | sed -E 's/psql: error: *//; s/connection to server at [^ ]+ \([^)]*\), port [0-9]+ failed: *//')
      echo "${MSG:0:58}" ;;
  esac
done

if [ -z "$FOUND_HOST" ]; then
  red "No route authenticated. .env.local has NOT been changed."
  echo
  echo "  Every route was tried with the password you entered, so if all of them"
  echo "  say 'password refused', the password is wrong — reset it at"
  echo "  Supabase → Project Settings → Database and try again."
  echo
  echo "  If they say 'unreachable from here', this machine has no route: the"
  echo "  direct host is IPv6-only, and the pooler needs outbound 5432/6543."
  exit 1
fi

HOST="$FOUND_HOST"; PORT="$FOUND_PORT"; PG_USER="$FOUND_USER"
blue "==> Using ${PG_USER}@${HOST}:${PORT}"

# What the database says about itself, which is the reason to have psql at all.
VERSION=$(PGCONNECT_TIMEOUT=8 PGPASSWORD="$PW" psql --no-psqlrc -tA -h "$HOST" -p "$PORT" \
            -U "$PG_USER" -d postgres \
            -c "select coalesce(max(version), 'not recorded') from public.schema_migrations" 2>/dev/null || echo 'no schema_migrations table')
blue "==> Schema version: ${VERSION}"

# ── Write, keeping a backup ──────────────────────────────────────────────────
# .gitignore already covers .env*.bak, so the copy cannot be committed.
URL="postgresql://${PG_USER}:$(printf '%s' "$PW" | python3 -c 'import sys,urllib.parse;sys.stdout.write(urllib.parse.quote(sys.stdin.read(), safe=""))')@${HOST}:${PORT}/postgres"
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
