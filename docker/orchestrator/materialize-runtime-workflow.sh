#!/usr/bin/env sh
set -eu

if [ "$#" -ne 3 ]; then
  echo "usage: $0 SOURCE_WORKFLOW OVERLAY_FILE RUNTIME_WORKFLOW" >&2
  exit 64
fi

source_workflow="$1"
overlay_file="$2"
runtime_workflow="$3"

test -f "$source_workflow" || {
  echo "missing source workflow: $source_workflow" >&2
  exit 1
}
test -s "$overlay_file" || {
  echo "missing or empty workflow overlay: $overlay_file" >&2
  exit 1
}

mkdir -p "$(dirname "$runtime_workflow")"
awk '
  /^# DOKS Linear-read guard$/ { exit }
  { print }
' "$source_workflow" > "$runtime_workflow"
printf '\n' >> "$runtime_workflow"
cat "$overlay_file" >> "$runtime_workflow"
