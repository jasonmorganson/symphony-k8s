#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$ROOT_DIR/workflow/WORKFLOW.md"
worker_patch="$ROOT_DIR/k8s/digitalocean/single-node-worker-patch.yaml"
worker_statefulset="$ROOT_DIR/k8s/base/worker-statefulset.yaml"

grep -q '^  interval_ms: 15000$' "$workflow"
grep -q '^  max_concurrent_agents_per_host: 1$' "$workflow"
grep -q '^  max_concurrent_agents: 5$' "$workflow"
grep -q '^  max_turns: 20$' "$workflow"
grep -q '^  max_concurrent_agents_by_state:$' "$workflow"
grep -q '^    Merging: 1$' "$workflow"
grep -q 'model_reasoning_effort=medium' "$workflow"
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

if grep -q 'model_auto_compact_token_limit' "$workflow"; then
  echo "workflow reintroduced the compaction override that increased live token slope" >&2
  exit 1
fi

grep -A5 'requests:' "$worker_patch" | grep -q 'cpu: "2"'
grep -A5 'requests:' "$worker_patch" | grep -q 'memory: 4Gi'
grep -A3 'limits:' "$worker_patch" | grep -q 'cpu: "4"'
grep -A3 'limits:' "$worker_patch" | grep -q 'memory: 6Gi'
grep -A2 'updateStrategy:' "$worker_statefulset" | grep -q 'type: OnDelete'

echo "workflow cost-control tests passed"
