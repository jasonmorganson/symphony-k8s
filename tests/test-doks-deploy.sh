#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

cat > "$TEMP_DIR/kubectl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KUBECTL_LOG"
if [[ "$*" == *" get deployment "* ]]; then
  deployment="${5}"
  if [[ ",${API_ERROR_DEPLOYMENTS:-}," == *",$deployment,"* ]]; then
    exit 1
  fi
  if [[ ",${MISSING_DEPLOYMENTS:-}," != *",$deployment,"* ]]; then
    printf 'deployment.apps/%s\n' "$deployment"
  fi
fi
EOF
chmod +x "$TEMP_DIR/kubectl"

export KUBECTL_LOG="$TEMP_DIR/kubectl.log"
KUBECTL="$TEMP_DIR/kubectl" \
  SYMPHONY_SYSTEM_NODE_POOL=durable-system \
  bash "$ROOT_DIR/scripts/deploy-digitalocean.sh"

grep -F "apply -k $ROOT_DIR/k8s/digitalocean" "$KUBECTL_LOG"
for deployment in coredns konnectivity-agent hubble-relay hubble-ui; do
  grep -F -- "-n kube-system patch deployment $deployment --type=strategic" "$KUBECTL_LOG"
  grep -F -- "-n kube-system rollout status deployment/$deployment --timeout=5m" "$KUBECTL_LOG"
done
grep -F '"doks.digitalocean.com/node-pool":"durable-system"' "$KUBECTL_LOG"
grep -F '"key":"symphony.morganson.me/workload"' "$KUBECTL_LOG"

: > "$KUBECTL_LOG"
KUBECTL="$TEMP_DIR/kubectl" \
  MISSING_DEPLOYMENTS=hubble-relay,hubble-ui \
  bash "$ROOT_DIR/scripts/deploy-digitalocean.sh"
for deployment in coredns konnectivity-agent; do
  grep -F -- "-n kube-system patch deployment $deployment --type=strategic" "$KUBECTL_LOG"
done
if grep -F -- "patch deployment hubble-" "$KUBECTL_LOG"; then
  echo "disabled optional Hubble deployments must not be patched" >&2
  exit 1
fi

: > "$KUBECTL_LOG"
if KUBECTL="$TEMP_DIR/kubectl" MISSING_DEPLOYMENTS=coredns \
    bash "$ROOT_DIR/scripts/deploy-digitalocean.sh"; then
  echo "missing required deployment must fail preflight" >&2
  exit 1
fi
if grep -F "apply -k" "$KUBECTL_LOG"; then
  echo "overlay must not be applied after failed preflight" >&2
  exit 1
fi

: > "$KUBECTL_LOG"
if KUBECTL="$TEMP_DIR/kubectl" API_ERROR_DEPLOYMENTS=hubble-relay \
    bash "$ROOT_DIR/scripts/deploy-digitalocean.sh"; then
  echo "optional deployment API errors must fail preflight" >&2
  exit 1
fi
if grep -F "apply -k" "$KUBECTL_LOG"; then
  echo "overlay must not be applied after an optional deployment API error" >&2
  exit 1
fi
