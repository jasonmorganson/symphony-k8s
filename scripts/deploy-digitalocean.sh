#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECTL="${KUBECTL:-kubectl}"
SYSTEM_POOL="${SYMPHONY_SYSTEM_NODE_POOL:-symphony-system}"

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
