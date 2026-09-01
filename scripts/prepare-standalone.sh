#!/usr/bin/env bash
# =============================================================================
# prepare-standalone.sh — make the standalone bundle actually servable
# =============================================================================
# `output: 'standalone'` produces .next/standalone/server.js plus the minimum
# node_modules it needs — but Next deliberately does NOT copy the static assets
# into it. Two directories are left behind:
#
#   .next/static   the hashed CSS and JS chunks every page loads
#   public/        files served at the site root, here the CSV import templates
#
# Deploy without them and the application starts, passes its health check, and
# serves HTML with every stylesheet and script 404ing — a blank white page that
# looks like a broken app rather than a missing copy step. The download links on
# the two upload screens 404 the same way.
#
# Run automatically as `postbuild`, so it happens on Railway and locally without
# anyone having to remember it.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STANDALONE="$ROOT_DIR/.next/standalone"

if [ ! -d "$STANDALONE" ]; then
  # A build that produced no standalone output is a build configuration problem,
  # not something to paper over by exiting quietly.
  echo "prepare-standalone: .next/standalone is missing — did next.config.ts lose output: 'standalone'?" >&2
  exit 1
fi

mkdir -p "$STANDALONE/.next"
cp -R "$ROOT_DIR/.next/static" "$STANDALONE/.next/static"

if [ -d "$ROOT_DIR/public" ]; then
  cp -R "$ROOT_DIR/public" "$STANDALONE/public"
fi

printf 'prepare-standalone: copied static assets%s into .next/standalone\n' \
  "$([ -d "$ROOT_DIR/public" ] && echo ' and public/')"
