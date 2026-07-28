#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
worker_patch="$ROOT_DIR/k8s/digitalocean/single-node-worker-patch.yaml"
worker_statefulset="$ROOT_DIR/k8s/base/worker-statefulset.yaml"
orchestrator_deployment="$ROOT_DIR/k8s/base/orchestrator-deployment.yaml"
runtime="$ROOT_DIR/config/workflow-runtime.yaml"
generator="$ROOT_DIR/scripts/generate-skaffold-inputs.sh"
throughput_overlay="$ROOT_DIR/config/workflow-throughput-overlay.md"
autoscaler="$ROOT_DIR/k8s/digitalocean/autoscaler.yaml"
kustomization="$ROOT_DIR/k8s/kustomization.yaml"
release_dockerfile="$ROOT_DIR/docker/release/Dockerfile"

grep -q '^worker:$' "$runtime"
grep -q 'symphony-worker-9.symphony-worker.symphony.svc.cluster.local' "$runtime"
grep -q '^  max_concurrent_agents: 10$' "$runtime"
grep -q '^  max_turns: 10$' "$runtime"
for state in 'In Progress' Merging Rework; do
  grep -A3 '^  continuation_delay_ms_by_state:' "$runtime" | \
    grep -q "^    $state: 60000$"
done
grep -A3 '^  dispatch_state_order:' "$runtime" | grep -q -- '- Merging'
grep -A3 '^  dispatch_priority_labels:' "$runtime" | grep -q -- '- production-gate'
grep -A3 '^  dispatch_priority_labels:' "$runtime" | grep -q -- '- main-ci'
if grep -q '^  max_concurrent_agents_by_state:' "$runtime"; then
  echo "Merging must inherit the global agent limit without a per-state ceiling" >&2
  exit 1
fi
[[ "$(grep -c '^    - symphony-worker-[0-9]' "$runtime")" -eq 10 ]]
grep -q '^  root: /srv/symphony/workspaces$' "$runtime"
grep -q -- '--model gpt-5.6 app-server' "$runtime"
grep -q 'model_reasoning_effort=medium' "$runtime"
grep -q 'agents.max_threads=3' "$runtime"
grep -q '^  drain_state_path: /srv/symphony/workspaces/.worker-drains.json$' "$runtime"
grep -q '^ARG SYMPHONY_COMMIT=066cf173060b99cd254b3ebf6fe8f49b9835fb35$' \
  "$release_dockerfile"
grep -A1 '^hooks:$' "$runtime" | grep -q '^  timeout_ms: 600000$'
grep -q 'render-workflow.sh' "$generator"
grep -q 'workflow-throughput-overlay.md' "$generator"
grep -q "SYMPHONY_WORKFLOW_FILE" "$generator"
grep -q 'SYMPHONY_WORKER_DRAIN_TOKEN' "$generator"
grep -q 'requester-policy.json' "$generator"
grep -q 'workflow-source.json' "$generator"
grep -q 'SYMPHONY_REQUIRE_CLEAN_MAIN_SOURCE' "$generator"
grep -q '^## External-wait checkpoint$' "$throughput_overlay"
grep -q '^## Parallel merge preparation and final-writer lease$' "$throughput_overlay"
grep -q '"action":"yield"' "$throughput_overlay"
grep -q '"action":"acquire"' "$throughput_overlay"
grep -q '"action":"release"' "$throughput_overlay"
grep -q 'explicit release is required' "$throughput_overlay"
grep -q '^## Exact-state validation evidence$' "$throughput_overlay"
grep -q -- '- `head_sha`:' "$throughput_overlay"
grep -q -- '- `main_sha`:' "$throughput_overlay"
grep -q -- '- `config_digest`:' "$throughput_overlay"
grep -q 'never replaces required GitHub' "$throughput_overlay"
grep -q '^## Shared-gate repair classification$' "$throughput_overlay"
grep -q 'During normal Symphony workpad reconciliation' "$throughput_overlay"
grep -q 'add its missing matching label through the workflow' "$throughput_overlay"
grep -q 'same workflow-owned create/update sequence' "$throughput_overlay"
grep -q 'Do not rely on an operator, monitor, or other' "$throughput_overlay"
grep -q 'requester-policy.json=base/generated/skaffold/workflow/requester-policy.json' "$kustomization"
grep -q 'workflow-source.json=base/generated/skaffold/workflow/workflow-source.json' "$kustomization"
grep -A4 'name: GITHUB_TOKEN' "$autoscaler" | grep -q 'name: github-machine-arrusted-symphony'
grep -A2 'name: REQUESTER_POLICY_PATH' "$autoscaler" | \
  grep -q '/etc/symphony-workflow/requester-policy.json'
grep -A1 'name: APPROVAL_HANDOFF_RETRY_SECONDS' "$autoscaler" | grep -q 'value: "300"'
grep -A1 'name: POLL_INTERVAL_SECONDS' "$autoscaler" | grep -q 'value: "15"'
grep -A1 'name: APPROVAL_HANDOFF_POLL_SECONDS' "$autoscaler" | grep -q 'value: "60"'
grep -A1 'name: RETRY_CAPACITY_WARMUP_SECONDS' "$autoscaler" | grep -q 'value: "300"'
grep -A5 'name: workflow$' "$autoscaler" | grep -q 'requester-policy.json'
grep -A4 'name: symphony-workflow$' "$autoscaler" | grep -q 'optional: true'
if grep -A8 '^  active_states:' "$runtime" | grep -q 'Human Review'; then
  echo "Human Review must remain passive and absent from tracker.active_states" >&2
  exit 1
fi
for state in Merging Rework; do
  if ! grep -A8 '^  active_states:' "$runtime" | grep -q -- "- $state"; then
    echo "$state must remain active in the upstream Symphony workflow" >&2
    exit 1
  fi
done
grep -q 'symphony-worker-9.symphony-worker.symphony.svc.cluster.local' "$generator"
grep -A1 'name: MAX_WORKERS' "$ROOT_DIR/k8s/digitalocean/autoscaler.yaml" | grep -q 'value: "10"'

if grep -q '^## ' "$runtime"; then
  echo "runtime front matter must not fork canonical behavioral instructions" >&2
  exit 1
fi

grep -A5 'requests:' "$worker_patch" | grep -q 'cpu: "2"'
grep -A5 'requests:' "$worker_patch" | grep -q 'memory: 4Gi'
grep -A3 'limits:' "$worker_patch" | grep -q 'cpu: "4"'
grep -A3 'limits:' "$worker_patch" | grep -q 'memory: 6Gi'
grep -A2 'updateStrategy:' "$worker_statefulset" | grep -q 'type: OnDelete'
grep -q 'mkdir -p /srv/worker-data/local-home/state/mise' "$worker_statefulset"
grep -A2 'mountPath: /home/symphony/.local' "$worker_statefulset" | \
  grep -q 'subPath: local-home'
grep -q -- '- "/etc/symphony-workflow/WORKFLOW.md"' "$orchestrator_deployment"
grep -A2 'name: workflow$' "$orchestrator_deployment" | \
  grep -q 'mountPath: /etc/symphony-workflow'
if grep -A3 'name: workflow$' "$orchestrator_deployment" | grep -q 'subPath:'; then
  echo "orchestrator workflow mount must support ConfigMap hot reload" >&2
  exit 1
fi
grep -A28 'name: workspace-reclaimer' "$worker_statefulset" | \
  grep -q 'WORKSPACE_RECLAIMER_INTERVAL_SECONDS'
grep -A30 'name: workspace-reclaimer' "$worker_statefulset" | \
  grep -q 'WORKSPACE_RECLAIMER_GRACE_SECONDS'
grep -A32 'name: workspace-reclaimer' "$worker_statefulset" | \
  grep -q 'WORKSPACE_RECLAIMER_CONFIRMATIONS'

echo "workflow cost-control tests passed"
