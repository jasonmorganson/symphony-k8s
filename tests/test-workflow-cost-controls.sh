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
grep -q 'finite page size of at most 25' "$throughput_overlay"
grep -q 'does not alter upstream' "$throughput_overlay"
grep -q '^# Consolidated review for mechanical main-CI repairs$' "$throughput_overlay"
grep -q 'one consolidated required review panel' "$throughput_overlay"
grep -q 'authoritative final gate on the final tree' "$throughput_overlay"
grep -q '^# Durable review proof across session boundaries$' "$throughput_overlay"
grep -q 'completed Review Batch remains valid across a continuation' \
  "$throughput_overlay"
grep -q 'do not launch another panel solely because the session' \
  "$throughput_overlay"
grep -q '^# Bound work when the reported failure does not reproduce$' \
  "$throughput_overlay"
grep -q 'make an explicit scope decision' "$throughput_overlay"
grep -q 'new repository-wide enforcement framework' "$throughput_overlay"
grep -q '^# Freeze a published head while its evidence is pending$' \
  "$throughput_overlay"
grep -q 'keep the code-bearing tree fixed' "$throughput_overlay"
grep -q 'only in response to a concrete classified check failure' \
  "$throughput_overlay"
grep -q '^# Dependency-upgrade scope budget$' "$throughput_overlay"
grep -q 'explicit scope-budget decision in the durable workpad' "$throughput_overlay"
grep -q "ticket's bounded exception" "$throughput_overlay"
grep -q 'Do not silently turn a package update into a provider-tool migration' \
  "$throughput_overlay"
if grep -q 'symphony_merge_writer\\|action.*acquire\\|action.*yield' "$throughput_overlay"; then
  echo "workflow overlay must not install custom merge serialization" >&2
  exit 1
fi

grep -A1 'name: MIN_WORKERS' "$autoscaler" | grep -q 'value: "0"'
grep -A1 'name: MAX_WORKERS' "$autoscaler" | grep -q 'value: "10"'
grep -A1 'name: POLL_INTERVAL_SECONDS' "$autoscaler" | grep -q 'value: "15"'
grep -A1 'name: DEMAND_MAX_AGE_SECONDS' "$autoscaler" | grep -q 'value: "300"'
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
