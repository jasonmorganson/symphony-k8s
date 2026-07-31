#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="$(mktemp)"
trap 'rm -f "$output"' EXIT

if bash "$ROOT_DIR/scripts/reconcile-production.sh" \
    "$ROOT_DIR/environments/production/desired-state.yaml" \
    "$ROOT_DIR" >"$output" 2>&1; then
  echo "reconciliation accepted images built from the wrong Symphony revision" >&2
  exit 1
fi
grep -q 'published images do not yet prove the desired Symphony revision' "$output"
echo "image provenance guard is fail closed"
