#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: render-production.sh DESIRED_STATE WORKFLOW_CHECKOUT OUTPUT" >&2
  exit 64
fi

desired_state="$1"
workflow_checkout="$2"
output="$3"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow_path="$(ruby -ryaml -e 'd=YAML.safe_load(File.read(ARGV[0])); print d.dig("spec","workflow","path")' "$desired_state")"
workflow_revision="$(ruby -ryaml -e 'd=YAML.safe_load(File.read(ARGV[0])); print d.dig("spec","workflow","revision")' "$desired_state")"
actual_revision="$(git -C "$workflow_checkout" rev-parse HEAD)"
if [[ "$actual_revision" != "$workflow_revision" ]]; then
  echo "workflow checkout is stale: expected $workflow_revision, got $actual_revision" >&2
  exit 1
fi

temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
ruby "$repo_root/scripts/render-runtime-workflow.rb" \
  "$desired_state" "$workflow_checkout/$workflow_path" \
  "$temporary/WORKFLOW.md" "$temporary/provenance.json"

kustomize_command=(kubectl kustomize)
if command -v kustomize >/dev/null 2>&1; then
  kustomize_command=(kustomize build)
fi
"${kustomize_command[@]}" "$repo_root/k8s/digitalocean" > "$temporary/base.yaml"
ruby "$repo_root/scripts/render-production-manifests.rb" \
  "$desired_state" "$temporary/WORKFLOW.md" "$temporary/provenance.json" \
  "$temporary/base.yaml" "$output"
