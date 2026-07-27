#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 3 ]]; then
  echo "usage: $0 RUNTIME_FILE CANONICAL_WORKFLOW_FILE OVERLAY_FILE" >&2
  exit 64
fi

runtime_file="$1"
workflow_file="$2"
overlay_file="$3"

for input in "$runtime_file" "$workflow_file" "$overlay_file"; do
  if [[ ! -f "$input" ]]; then
    echo "missing workflow render input: $input" >&2
    exit 1
  fi
done

workflow_body="$(awk '
  BEGIN { separators = 0 }
  /^---$/ { separators++; next }
  separators >= 2 { print }
' "$workflow_file")"
if [[ -z "$workflow_body" ]]; then
  echo "canonical workflow has no prompt body after YAML front matter: $workflow_file" >&2
  exit 1
fi
if [[ ! -s "$overlay_file" ]]; then
  echo "workflow throughput overlay is empty: $overlay_file" >&2
  exit 1
fi

printf '%s\n%s\n%s\n%s\n\n%s\n' \
  '---' \
  "$(cat "$runtime_file")" \
  '---' \
  "$workflow_body" \
  "$(cat "$overlay_file")"
