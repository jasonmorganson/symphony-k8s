#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runtime="$ROOT_DIR/config/workflow-runtime.yaml"
generator="$ROOT_DIR/scripts/generate-skaffold-inputs.sh"
throughput_overlay="$ROOT_DIR/config/workflow-throughput-overlay.md"
autoscaler="$ROOT_DIR/k8s/digitalocean/autoscaler.yaml"
worker_statefulset="$ROOT_DIR/k8s/base/worker-statefulset.yaml"
orchestrator_deployment="$ROOT_DIR/k8s/base/orchestrator-deployment.yaml"
release_dockerfile="$ROOT_DIR/docker/release/Dockerfile"

grep -q '^worker:$' "$runtime"
grep -q 'symphony-worker-9.symphony-worker.symphony.svc.cluster.local' "$runtime"
grep -q '^  max_concurrent_agents: 10$' "$runtime"
grep -q '^  max_turns: 10$' "$runtime"
if grep -q '^  recovery_issue_ids:' "$runtime"; then
  echo "one-shot recovery targets must be removed after workflow-owned recovery" >&2
  exit 1
fi
grep -q '^  drain_state_path: /srv/symphony/workspaces/.worker-drains.json$' "$runtime"
[[ "$(grep -c '^    - symphony-worker-[0-9]' "$runtime")" -eq 10 ]]

for custom_scheduler_key in \
  continuation_delay_ms_by_state \
  dispatch_state_order \
  dispatch_priority_labels \
  max_concurrent_agents_by_state; do
  if grep -q "$custom_scheduler_key" "$runtime"; then
    echo "upstream scheduling must not be overridden by $custom_scheduler_key" >&2
    exit 1
  fi
done

grep -q 'render-workflow.sh' "$generator"
grep -q 'workflow-throughput-overlay.md' "$generator"
grep -q 'workflow-source.json' "$generator"
grep -q 'SYMPHONY_REQUIRE_CLEAN_MAIN_SOURCE' "$generator"
if grep -q 'requester-policy\\|python3\\|autoscaler.scaler' "$generator"; then
  echo "workflow generation must not retain the Python approval monitor" >&2
  exit 1
fi

grep -q '^# DOKS Linear-read guard$' "$throughput_overlay"
grep -q '^# Recover an explicitly stranded active issue$' "$throughput_overlay"
grep -q 'This recovery rule has higher precedence than every generic `Backlog -> stop`' \
  "$throughput_overlay"
grep -q 'do not execute those generic Backlog routes' "$throughput_overlay"
grep -q 'restore it to its most recent appropriate active implementation state using the' \
  "$throughput_overlay"
grep -q 'Do not end, yield, or defer the' "$throughput_overlay"
grep -q 'Recovery never authorizes merge, provider' "$throughput_overlay"
grep -q 'finite page size of at most 25' "$throughput_overlay"
grep -q 'does not alter upstream' "$throughput_overlay"
grep -q '^# Consolidated review for mechanical main-CI repairs$' "$throughput_overlay"
grep -q 'one consolidated required review panel' "$throughput_overlay"
grep -q 'authoritative final gate on the final tree' "$throughput_overlay"
grep -q '^# Bound long-running command output$' "$throughput_overlay"
grep -q 'git rev-parse --git-path symphony-logs' "$throughput_overlay"
grep -q 'stdout and stderr' "$throughput_overlay"
grep -q 'preserving its exact exit status' "$throughput_overlay"
grep -q 'Do not repeatedly stream or reread the accumulated log' "$throughput_overlay"
grep -q 'at most the final 200 relevant lines' "$throughput_overlay"
grep -q 'must never hide a nonzero exit' "$throughput_overlay"
grep -q '^# Bound provider evidence probes$' "$throughput_overlay"
grep -q 'non-interactive timeout of at most 90 seconds' "$throughput_overlay"
grep -q 'terminate the entire probe' "$throughput_overlay"
grep -q 'Skipped hosted CI on a draft pull request is not executable validation' \
  "$throughput_overlay"
grep -q "Inspect the skipped job's checked workflow definition" "$throughput_overlay"
grep -q 'different broader gate is not a substitute' "$throughput_overlay"
grep -q 'deferring this lane for provider or human evidence' "$throughput_overlay"
grep -q 'required hosted job that was skipped lacks a durable exact-command local receipt' \
  "$throughput_overlay"
grep -q 'Do not make a draft ready merely to cause CI to run' "$throughput_overlay"
grep -q '^# Dependency-upgrade scope budget$' "$throughput_overlay"
grep -q 'explicit scope-budget decision in the durable workpad' "$throughput_overlay"
grep -q "ticket's bounded exception" "$throughput_overlay"
grep -q 'Do not silently turn a package update into a provider-tool migration' \
  "$throughput_overlay"
grep -q '^# Retain Merging through post-merge verification$' "$throughput_overlay"
grep -q 'Never move the issue from `Merging` to `In Progress`, `Human' \
  "$throughput_overlay"
grep -q 'containing-main proof has not completed yet' "$throughput_overlay"
grep -q "Resolve and freeze the issue's containing-main revision" "$throughput_overlay"
grep -q 'do not hold the' "$throughput_overlay"
grep -q 'agent turn open with `gh run watch`' "$throughput_overlay"
grep -q 'call `symphony_report_turn_outcome` with outcome `defer`' "$throughput_overlay"
grep -q 'Symphony will revisit the' "$throughput_overlay"
grep -q 'issue on a later rate-limited turn' "$throughput_overlay"
grep -q 'do not advance the proof target to a newer' "$throughput_overlay"
grep -q 'transition the issue directly from `Merging` to' "$throughput_overlay"
grep -q 'When a required post-merge gate fails, keep' "$throughput_overlay"
grep -q 'the issue in `Merging` and follow the canonical failure-repair' \
  "$throughput_overlay"
if grep -q 'symphony_merge_writer\\|action.*acquire\\|action.*yield' "$throughput_overlay"; then
  echo "workflow overlay must not install custom merge serialization" >&2
  exit 1
fi

grep -A1 'name: MIN_WORKERS' "$autoscaler" | grep -q 'value: "0"'
grep -A1 'name: MAX_WORKERS' "$autoscaler" | grep -q 'value: "10"'
grep -A1 'name: POLL_INTERVAL_SECONDS' "$autoscaler" | grep -q 'value: "15"'
grep -A1 'name: SCALE_DOWN_STABILIZATION_SECONDS' "$autoscaler" | grep -q 'value: "90"'
grep -A1 'name: DEMAND_MAX_AGE_SECONDS' "$autoscaler" | grep -q 'value: "300"'
grep -A1 'name: RETRY_WARMUP_SECONDS' "$autoscaler" | grep -q 'value: "120"'
grep -q 'path: /readyz' "$autoscaler"
grep -q 'path: /healthz' "$autoscaler"
if grep -q 'LINEAR_API_KEY\\|GITHUB_TOKEN\\|usage-ledger\\|requester-policy' "$autoscaler"; then
  echo "autoscaler must not receive workflow credentials or persistent state" >&2
  exit 1
fi

grep -A8 'name: workspace-reclaimer' "$worker_statefulset" |
  grep -q '/usr/local/bin/workspace-reclaimer'
if grep -A4 'name: workspace-reclaimer' "$worker_statefulset" | grep -q 'python'; then
  echo "workspace reclaimer must execute the Rust binary directly" >&2
  exit 1
fi
reclaimer_block="$(sed -n '/- name: workspace-reclaimer/,/resources:/p' "$worker_statefulset")"
printf '%s\n' "$reclaimer_block" | grep -q 'name: SYMPHONY_WORKER_DRAIN_TOKEN'
if printf '%s\n' "$reclaimer_block" | grep -q 'LINEAR_API_KEY'; then
  echo "workspace reclaimer must read terminal state through Symphony" >&2
  exit 1
fi

grep -A1 'name: SYMPHONY_EXTERNAL_WORKSPACE_RECLAIMER' "$orchestrator_deployment" |
  grep -q 'value: "true"' || {
  echo "orchestrator must delegate startup cleanup to the Rust reclaimer" >&2
  exit 1
}

grep -q '^ARG SYMPHONY_COMMIT=' "$release_dockerfile"

echo "workflow and control-plane tests passed"
