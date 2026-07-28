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
grep -Fq 'dispatch, review, Merging, landing, or Linear-transition behavior.' \
  "$TEMP_DIR/throughput-rendered.md"
if grep -Eq 'symphony_merge_writer|"action":"(yield|acquire|release)"' \
    "$TEMP_DIR/throughput-rendered.md"; then
  echo "throughput overlay must not serialize Merging work" >&2
  exit 1
fi

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
