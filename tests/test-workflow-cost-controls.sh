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
grep -q 'model_reasoning_effort=medium' "$workflow"
grep -q 'model_auto_compact_token_limit=120000' "$workflow"
grep -q 'model_auto_compact_token_limit_scope=total' "$workflow"
grep -q 'Keep at most 12 concise `Notes` bullets' "$workflow"
grep -q 'Deduplicate overlapping findings by root cause' "$workflow"
grep -q 'reviewThreads(first: 100, after: \$cursor)' "$workflow"
grep -q 'pageInfo.hasNextPage' "$workflow"
grep -q 'later feedback-driven code' "$workflow"
grep -q 'change invalidates that gate' "$workflow"
grep -q 'git clone --filter=blob:none' "$workflow"

if grep -Eq 'full (required|repository) gate once' "$workflow"; then
  echo "workflow incorrectly caps full validation after later code changes" >&2
  exit 1
fi

if grep -A12 '^  active_states:' "$workflow" | grep -q 'Human Review'; then
  echo "Human Review must not dispatch unattended Codex sessions" >&2
  exit 1
fi

if grep -Eq 'model_reasoning_effort=(high|xhigh)' "$workflow"; then
  echo "high-cost reasoning reintroduced into the default workflow" >&2
  exit 1
fi

if grep -Eq 'model_auto_compact_token_limit=([2-9][0-9]{5}|[1-9][0-9]{6,})' "$workflow"; then
  echo "workflow compaction threshold is too high for the cost-control canary" >&2
  exit 1
fi

echo "workflow cost-control tests passed"
