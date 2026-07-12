#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$ROOT_DIR/workflow/WORKFLOW.md"

grep -q '^  interval_ms: 15000$' "$workflow"
grep -q '^  max_concurrent_agents_per_host: 1$' "$workflow"
grep -q '^  max_concurrent_agents: 5$' "$workflow"
grep -q '^  max_turns: 20$' "$workflow"
grep -q '^  max_concurrent_agents_by_state:$' "$workflow"
grep -q '^    Merging: 1$' "$workflow"
grep -q 'model_reasoning_effort=high' "$workflow"

if grep -A12 '^  active_states:' "$workflow" | grep -q 'Human Review'; then
  echo "Human Review must not dispatch unattended Codex sessions" >&2
  exit 1
fi

if grep -q 'model_reasoning_effort=xhigh' "$workflow"; then
  echo "xhigh reasoning reintroduced into the default workflow" >&2
  exit 1
fi

echo "workflow cost-control tests passed"
