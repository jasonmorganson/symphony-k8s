#!/usr/bin/env sh
set -eu

if [ "$#" -ne 4 ]; then
  echo "usage: $0 RUNTIME_CONFIG SOURCE_WORKFLOW OVERLAY_FILE RUNTIME_WORKFLOW" >&2
  exit 64
fi

runtime_config="$1"
source_workflow="$2"
overlay_file="$3"
runtime_workflow="$4"

test -s "$runtime_config" || {
  echo "missing or empty runtime config: $runtime_config" >&2
  exit 1
}
test -f "$source_workflow" || {
  echo "missing source workflow: $source_workflow" >&2
  exit 1
}
test -s "$overlay_file" || {
  echo "missing or empty workflow overlay: $overlay_file" >&2
  exit 1
}

mkdir -p "$(dirname "$runtime_workflow")"
printf '%s\n' '---' > "$runtime_workflow"
cat "$runtime_config" >> "$runtime_workflow"
printf '%s\n' '---' >> "$runtime_workflow"
awk '
  NR == 1 && $0 == "---" { frontmatter = 1; next }
  frontmatter && $0 == "---" { frontmatter = 0; next }
  frontmatter { next }
  /^# DOKS Linear-read guard$/ { exit }
  { print }
' "$source_workflow" >> "$runtime_workflow"
printf '\n' >> "$runtime_workflow"
cat "$overlay_file" >> "$runtime_workflow"
