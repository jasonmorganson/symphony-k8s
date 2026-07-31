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

apply_count="$(grep -c 'kubectl apply --server-side' "$ROOT_DIR/scripts/reconcile-production.sh")"
[[ "$apply_count" == 1 ]] || {
  echo "production reconciliation bypasses the centralized GitOps field manager" >&2
  exit 1
}
grep -q -- 'kubectl apply --server-side --force-conflicts --field-manager=symphony-gitops' \
  "$ROOT_DIR/scripts/reconcile-production.sh"
grep -q -- 'delete deployment symphony-autoscaler --ignore-not-found --wait=true' \
  "$ROOT_DIR/scripts/reconcile-production.sh"
grep -q -- '"op" => "test".*"workspace-reclaimer"' \
  "$ROOT_DIR/scripts/reconcile-production.sh"
grep -q -- '"op" => "remove"' "$ROOT_DIR/scripts/reconcile-production.sh"
grep -q -- 'unknown legacy worker volume claims; refusing recreation' \
  "$ROOT_DIR/scripts/reconcile-production.sh"
grep -q -- 'delete statefulset symphony-worker --cascade=orphan --wait=true' \
  "$ROOT_DIR/scripts/reconcile-production.sh"
grep -q -- 'init-workspace-permissions' "$ROOT_DIR/scripts/reconcile-production.sh"
[[ "$(grep -c 'wait_for_worker_convergence' "$ROOT_DIR/scripts/reconcile-production.sh")" == 3 ]] || {
  echo "worker reconciliation does not consistently wait for actual convergence" >&2
  exit 1
}
grep -q -- 'status\["currentRevision"\] == status\["updateRevision"\]' \
  "$ROOT_DIR/scripts/reconcile-production.sh"
grep -q -- 'workflow_dispatch:' "$ROOT_DIR/.github/workflows/validate.yml"
grep -q -- 'gh workflow run validate.yml --ref "$branch"' \
  "$ROOT_DIR/.github/workflows/publish-images.yml"

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
