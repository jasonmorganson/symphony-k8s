#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
worker_patch="$ROOT_DIR/k8s/digitalocean/single-node-worker-patch.yaml"
worker_statefulset="$ROOT_DIR/k8s/base/worker-statefulset.yaml"
runtime="$ROOT_DIR/config/workflow-runtime.yaml"
generator="$ROOT_DIR/scripts/generate-skaffold-inputs.sh"

grep -q '^worker:$' "$runtime"
grep -q 'symphony-worker-9.symphony-worker.symphony.svc.cluster.local' "$runtime"
grep -q '^  max_concurrent_agents: 10$' "$runtime"
grep -q '^  root: /srv/symphony/workspaces$' "$runtime"
grep -q 'model_reasoning_effort=medium' "$runtime"
grep -q 'agents.max_threads=3' "$runtime"
grep -q '^  drain_state_path: /srv/symphony/workspaces/.worker-drains.json$' "$runtime"
grep -q 'workflow_body=.*awk' "$generator"
grep -q "SYMPHONY_WORKFLOW_FILE" "$generator"
grep -q 'SYMPHONY_WORKER_DRAIN_TOKEN' "$generator"
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
