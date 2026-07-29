#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

runtime="$TEMP_DIR/runtime.yaml"
canonical="$TEMP_DIR/WORKFLOW.md"
overlay="$TEMP_DIR/overlay.md"

printf '%s\n' 'tracker:' '  kind: linear' > "$runtime"
printf '%s\n' \
  '---' \
  'tracker:' \
  '  kind: linear' \
  '---' \
  '# Canonical workflow' \
  'Canonical instruction.' \
  > "$canonical"
printf '%s\n' '# Deployment overlay' 'Overlay instruction.' > "$overlay"

"$ROOT_DIR/scripts/render-workflow.sh" \
  "$runtime" "$canonical" "$overlay" > "$TEMP_DIR/rendered.md"

[[ "$(grep -c '^tracker:$' "$TEMP_DIR/rendered.md")" == 1 ]]
grep -Fqx '# Canonical workflow' "$TEMP_DIR/rendered.md"
grep -Fqx 'Canonical instruction.' "$TEMP_DIR/rendered.md"
grep -Fqx '# Deployment overlay' "$TEMP_DIR/rendered.md"
grep -Fqx 'Overlay instruction.' "$TEMP_DIR/rendered.md"
canonical_line="$(grep -nF '# Canonical workflow' "$TEMP_DIR/rendered.md" | cut -d: -f1)"
overlay_line="$(grep -nF '# Deployment overlay' "$TEMP_DIR/rendered.md" | cut -d: -f1)"
(( canonical_line < overlay_line ))

"$ROOT_DIR/scripts/render-workflow.sh" \
  "$runtime" "$canonical" "$ROOT_DIR/config/workflow-throughput-overlay.md" \
  > "$TEMP_DIR/throughput-rendered.md"
grep -Fqx '# DOKS Linear-read guard' "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'finite page size of at most 25' "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'This read guard does not alter upstream' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'dispatch, Merging, landing, or Linear-transition behavior.' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fqx '# Consolidated review for mechanical main-CI repairs' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'one consolidated required review panel' "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'authoritative final gate on the final tree' "$TEMP_DIR/throughput-rendered.md"
grep -Fqx '# Dependency-upgrade scope budget' "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'explicit scope-budget decision in the durable workpad' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq "ticket's bounded exception" "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'Do not silently turn a package update into a provider-tool migration' \
  "$TEMP_DIR/throughput-rendered.md"
if grep -Eq 'symphony_merge_writer|"action":"(yield|acquire|release)"' \
    "$TEMP_DIR/throughput-rendered.md"; then
  echo "throughput overlay must not serialize Merging work" >&2
  exit 1
fi

printf '%s\n' \
  '# Canonical workflow' \
  'Canonical instruction.' \
  '# DOKS Linear-read guard' \
  'Stale deployment overlay.' \
  > "$TEMP_DIR/mounted-workflow.md"
"$ROOT_DIR/docker/orchestrator/materialize-runtime-workflow.sh" \
  "$TEMP_DIR/mounted-workflow.md" \
  "$ROOT_DIR/config/workflow-throughput-overlay.md" \
  "$TEMP_DIR/runtime-workflow.md"
grep -Fqx 'Canonical instruction.' "$TEMP_DIR/runtime-workflow.md"
grep -Fqx '# Consolidated review for mechanical main-CI repairs' \
  "$TEMP_DIR/runtime-workflow.md"
grep -Fqx '# Dependency-upgrade scope budget' "$TEMP_DIR/runtime-workflow.md"
if grep -Fq 'Stale deployment overlay.' "$TEMP_DIR/runtime-workflow.md"; then
  echo "runtime workflow must replace the stale mounted deployment overlay" >&2
  exit 1
fi
[[ "$(grep -Fc '# DOKS Linear-read guard' "$TEMP_DIR/runtime-workflow.md")" == 1 ]]
grep -Fq '/tmp/symphony-workflow/WORKFLOW.md' \
  "$ROOT_DIR/k8s/base/orchestrator-deployment.yaml"
grep -Fq 'materialize-runtime-workflow.sh' \
  "$ROOT_DIR/docker/orchestrator/entrypoint.sh"

if "$ROOT_DIR/scripts/render-workflow.sh" \
    "$runtime" "$canonical" "$TEMP_DIR/missing.md" >/dev/null 2>&1; then
  echo "missing throughput overlay must fail closed" >&2
  exit 1
fi

: > "$overlay"
if "$ROOT_DIR/scripts/render-workflow.sh" \
    "$runtime" "$canonical" "$overlay" >/dev/null 2>&1; then
  echo "empty throughput overlay must fail closed" >&2
  exit 1
fi

echo "workflow overlay tests passed"
