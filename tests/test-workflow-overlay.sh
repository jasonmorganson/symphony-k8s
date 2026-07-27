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
grep -Fq 'During normal Symphony workpad reconciliation' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq '## Exact-state validation evidence' "$TEMP_DIR/throughput-rendered.md"
grep -Fq '## Parallel merge preparation and final-writer lease' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq '"action":"yield"' "$TEMP_DIR/throughput-rendered.md"
grep -Fq '"action":"acquire"' "$TEMP_DIR/throughput-rendered.md"
grep -Fq '"action":"release"' "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'head_sha' "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'main_sha' "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'config_digest' "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'never replaces required GitHub' "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'add its missing matching label through the workflow' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'same workflow-owned create/update sequence' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'out-of-band Linear mutation' "$TEMP_DIR/throughput-rendered.md"

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
