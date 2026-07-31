#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

desired="$tmpdir/desired-state.yaml"
output="$tmpdir/output"
cp "$ROOT_DIR/environments/production/desired-state.yaml" "$desired"
ruby -e '
  path = ARGV.fetch(0)
  contents = File.read(path)
  pattern = /^(    built_from_symphony_revision:\s*).+$/
  abort "missing image provenance field" unless contents.match?(pattern)
  File.write(path, contents.sub(pattern) { "#{Regexp.last_match(1)}#{"0" * 40}" })
' "$desired"

if bash "$ROOT_DIR/scripts/reconcile-production.sh" \
    "$desired" \
    "$ROOT_DIR" >"$output" 2>&1; then
  echo "reconciliation accepted images built from the wrong Symphony revision" >&2
  exit 1
fi
grep -q 'published images do not yet prove the desired Symphony revision' "$output"

updater_input="$tmpdir/updater-input.yaml"
cp "$ROOT_DIR/environments/production/desired-state.yaml" "$updater_input"
ruby "$ROOT_DIR/scripts/update-image-digests.rb" \
  "$updater_input" \
  111111111111111111111111111111111111111a \
  ghcr.io/jasonmorganson/symphony-k8s-orchestrator@sha256:$(printf '2%.0s' {1..64}) \
  ghcr.io/jasonmorganson/symphony-k8s-worker@sha256:$(printf '3%.0s' {1..64})
ruby -e '
  target = /^    (?:built_from_symphony_revision|orchestrator|worker):/
  original = File.readlines(ARGV.fetch(0)).reject { |line| line.match?(target) }
  updated = File.readlines(ARGV.fetch(1)).reject { |line| line.match?(target) }
  abort "image updater rewrote unrelated desired state" unless original == updated
' "$ROOT_DIR/environments/production/desired-state.yaml" "$updater_input"

echo "image provenance guard is fail closed"
