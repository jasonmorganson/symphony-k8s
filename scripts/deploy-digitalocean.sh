#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECTL="${KUBECTL:-kubectl}"
DOCTL="${DOCTL:-doctl}"
DOKS_CLUSTER="${DOKS_CLUSTER:-symphony-k8s}"
SYSTEM_POOL="${SYMPHONY_SYSTEM_NODE_POOL:-symphony-system}"
WORKER_POOL="${SYMPHONY_WORKER_NODE_POOL:-symphony-ha}"
WORKER_MIN_NODES="${SYMPHONY_WORKER_MIN_NODES:-0}"
WORKER_MAX_NODES="${SYMPHONY_WORKER_MAX_NODES:-10}"

if [[ ! "$WORKER_MIN_NODES" =~ ^[0-9]+$ ]] ||
    [[ ! "$WORKER_MAX_NODES" =~ ^[0-9]+$ ]] ||
    (( WORKER_MAX_NODES < WORKER_MIN_NODES )); then
  echo "invalid worker node-pool bounds: min=$WORKER_MIN_NODES max=$WORKER_MAX_NODES" >&2
  exit 1
fi

required_addons=(coredns konnectivity-agent)
optional_addons=(hubble-relay hubble-ui)
addons=()

for deployment in "${required_addons[@]}"; do
  resource="$("$KUBECTL" -n kube-system get deployment "$deployment" --ignore-not-found -o name)"
  if [[ -z "$resource" ]]; then
    echo "required DOKS deployment is missing: $deployment" >&2
    exit 1
  fi
  addons+=("$deployment")
done

for deployment in "${optional_addons[@]}"; do
  resource="$("$KUBECTL" -n kube-system get deployment "$deployment" --ignore-not-found -o name)"
  if [[ -n "$resource" ]]; then
    addons+=("$deployment")
  fi
done

"$DOCTL" kubernetes cluster node-pool update "$DOKS_CLUSTER" "$WORKER_POOL" \
  --auto-scale \
  --min-nodes "$WORKER_MIN_NODES" \
  --max-nodes "$WORKER_MAX_NODES"

"$KUBECTL" apply -k "$ROOT_DIR/k8s/digitalocean"

patch="$(cat <<EOF
{"spec":{"template":{"spec":{"nodeSelector":{"doks.digitalocean.com/node-pool":"$SYSTEM_POOL"},"tolerations":[{"key":"symphony.morganson.me/workload","operator":"Equal","value":"system","effect":"NoSchedule"}]}}}}
EOF
)"

for deployment in "${addons[@]}"; do
  "$KUBECTL" -n kube-system patch deployment "$deployment" \
    --type=strategic --patch "$patch"
done

for deployment in "${addons[@]}"; do
  "$KUBECTL" -n kube-system rollout status "deployment/$deployment" --timeout=5m
done
