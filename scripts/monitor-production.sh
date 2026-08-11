#!/usr/bin/env bash
set -euo pipefail

# Read-only production monitor. Authentication is only the caller's Kubernetes
# credential (the scheduled workflow obtains a short-lived DO kubeconfig); the
# Symphony state API is reached through a localhost port-forward and needs no
# application token or other secret.
namespace="${NAMESPACE:-symphony}"
local_port="${SYMPHONY_MONITOR_PORT:-14001}"
temporary="$(mktemp -d)"
port_forward_pid=""

cleanup() {
  [[ -z "$port_forward_pid" ]] || kill "$port_forward_pid" 2>/dev/null || true
  rm -rf "$temporary"
}
trap cleanup EXIT

require_deployment_convergence() {
  kubectl -n "$namespace" get deployment/symphony-orchestrator -o json |
    ruby -rjson -e '
      workload = JSON.parse(STDIN.read)
      spec = workload.fetch("spec")
      status = workload.fetch("status", {})
      replicas = spec.fetch("replicas", 1)
      ready = status.fetch("readyReplicas", 0)
      available = status.fetch("availableReplicas", 0)
      observed = status.fetch("observedGeneration", 0)
      generation = workload.fetch("metadata").fetch("generation")
      abort "orchestrator deployment has not observed its current generation" unless observed >= generation
      abort "orchestrator deployment is not ready" unless ready == replicas && available == replicas
    '
}

require_worker_convergence() {
  kubectl -n "$namespace" get statefulset/symphony-worker -o json |
    ruby -rjson -e '
      workload = JSON.parse(STDIN.read)
      spec = workload.fetch("spec")
      status = workload.fetch("status", {})
      replicas = spec.fetch("replicas", 1)
      observed = status.fetch("observedGeneration", 0)
      generation = workload.fetch("metadata").fetch("generation")
      ready = status.fetch("readyReplicas", 0)
      updated = status.fetch("updatedReplicas", 0)
      current_revision = status["currentRevision"]
      update_revision = status["updateRevision"]
      abort "worker StatefulSet has not observed its current generation" unless observed >= generation
      abort "worker StatefulSet is not ready" unless ready == replicas && updated == replicas
      abort "worker StatefulSet revision is not converged" unless current_revision && current_revision == update_revision
    '
}

require_orchestrator_endpoint() {
  kubectl -n "$namespace" get endpoints/symphony-orchestrator -o json |
    ruby -rjson -e '
      endpoints = JSON.parse(STDIN.read)
      ready = (endpoints.fetch("subsets", []).flat_map { |subset| subset.fetch("addresses", []) })
      abort "orchestrator service has no ready endpoints" if ready.empty?
    '
}

require_state_api() {
  kubectl -n "$namespace" port-forward service/symphony-orchestrator "$local_port:4000" \
    >"$temporary/port-forward.log" 2>&1 &
  port_forward_pid=$!

  for _ in {1..30}; do
    if curl --fail --silent --show-error "http://127.0.0.1:${local_port}/api/v1/state" >"$temporary/state.json"; then
      [[ -s "$temporary/state.json" ]] && return 0
    fi
    sleep 1
  done

  echo "orchestrator state API is unavailable through its authenticated Kubernetes port-forward" >&2
  return 1
}

require_deployment_convergence
require_worker_convergence
require_orchestrator_endpoint
require_state_api

echo "production monitor verified workload convergence, service endpoints, and state API"
