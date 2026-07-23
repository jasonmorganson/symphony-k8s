#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
worker_patch="$ROOT_DIR/k8s/digitalocean/single-node-worker-patch.yaml"
worker_statefulset="$ROOT_DIR/k8s/base/worker-statefulset.yaml"
runtime="$ROOT_DIR/config/workflow-runtime.yaml"
generator="$ROOT_DIR/scripts/generate-skaffold-inputs.sh"
autoscaler="$ROOT_DIR/k8s/digitalocean/autoscaler.yaml"
kustomization="$ROOT_DIR/k8s/kustomization.yaml"

grep -q '^worker:$' "$runtime"
grep -q 'symphony-worker-9.symphony-worker.symphony.svc.cluster.local' "$runtime"
grep -q '^  max_concurrent_agents: 10$' "$runtime"
grep -q '^  root: /srv/symphony/workspaces$' "$runtime"
grep -q -- '--model gpt-5.6 app-server' "$runtime"
grep -q 'model_reasoning_effort=medium' "$runtime"
grep -q 'agents.max_threads=3' "$runtime"
grep -q '^  drain_state_path: /srv/symphony/workspaces/.worker-drains.json$' "$runtime"
grep -q 'workflow_body=.*awk' "$generator"
grep -q "SYMPHONY_WORKFLOW_FILE" "$generator"
grep -q 'SYMPHONY_WORKER_DRAIN_TOKEN' "$generator"
grep -q 'requester-policy.json' "$generator"
grep -q 'workflow-source.json' "$generator"
grep -q 'SYMPHONY_REQUIRE_CLEAN_MAIN_SOURCE' "$generator"
grep -q 'requester-policy.json=base/generated/skaffold/workflow/requester-policy.json' "$kustomization"
grep -q 'workflow-source.json=base/generated/skaffold/workflow/workflow-source.json' "$kustomization"
grep -A4 'name: GITHUB_TOKEN' "$autoscaler" | grep -q 'name: github-machine-arrusted-symphony'
grep -A2 'name: REQUESTER_POLICY_PATH' "$autoscaler" | \
  grep -q '/etc/symphony-workflow/requester-policy.json'
grep -A1 'name: APPROVAL_HANDOFF_RETRY_SECONDS' "$autoscaler" | grep -q 'value: "300"'
grep -A1 'name: POLL_INTERVAL_SECONDS' "$autoscaler" | grep -q 'value: "60"'
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

echo "workflow cost-control tests passed"
