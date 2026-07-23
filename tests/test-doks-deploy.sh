#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

cat > "$TEMP_DIR/kubectl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KUBECTL_LOG"

if [[ "$*" == "get --raw "* ]]; then
  case "${STATE_MODE:-idle}" in
    idle)
      printf '%s\n' '{"running":[],"retrying":[]}'
      ;;
    busy)
      printf '%s\n' '{"running":[{"issue_identifier":"A-230"}],"retrying":[]}'
      ;;
    busy_then_idle)
      count=0
      if [[ -f "$STATE_COUNT_FILE" ]]; then
        count="$(cat "$STATE_COUNT_FILE")"
      fi
      count=$((count + 1))
      printf '%s\n' "$count" > "$STATE_COUNT_FILE"
      if (( count == 1 )); then
        printf '%s\n' '{"running":[{"issue_identifier":"A-230"}],"retrying":[]}'
      else
        printf '%s\n' '{"running":[],"retrying":[{"issue_identifier":"A-211"}]}'
      fi
      ;;
    invalid)
      printf '%s\n' '{"running":"not-an-array"}'
      ;;
    unavailable)
      exit 1
      ;;
  esac
  exit 0
fi

if [[ "$*" == *" get deployment "* ]]; then
  deployment="${5}"
  if [[ ",${API_ERROR_DEPLOYMENTS:-}," == *",$deployment,"* ]]; then
    exit 1
  fi
  if [[ ",${MISSING_DEPLOYMENTS:-}," != *",$deployment,"* ]]; then
    printf 'deployment.apps/%s\n' "$deployment"
  fi
  exit 0
fi

if [[ "$*" == *" get statefulset symphony-worker "* ]] &&
    [[ "$*" == *"jsonpath={.spec.replicas}"* ]]; then
  printf '%s' "${WORKER_REPLICAS:-2}"
  exit 0
fi

if [[ "$*" == *" get statefulset symphony-worker "* ]]; then
  printf '%s' "$WORKER_IMAGE"
  exit 0
fi

if [[ "$*" == *" rollout status "* ]] &&
    [[ -n "${KUBECTL_FAIL_ROLLOUT:-}" ]] &&
    [[ "$*" == *"$KUBECTL_FAIL_ROLLOUT"* ]]; then
  exit 1
fi
EOF
chmod +x "$TEMP_DIR/kubectl"

cat > "$TEMP_DIR/doctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCTL_LOG"
if [[ "${DOCTL_ERROR:-0}" == "1" ]]; then
  exit 1
fi
EOF
chmod +x "$TEMP_DIR/doctl"

cat > "$TEMP_DIR/kustomize" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KUSTOMIZE_LOG"
if [[ "${KUSTOMIZE_ERROR:-0}" == "1" ]]; then
  exit 1
fi
if [[ "${1:-}" == "build" ]]; then
  worker_replicas="$(awk '/^  replicas: / { print $2; exit }' \
    "$2/single-node-worker-patch.yaml")"
  printf 'build worker_replicas=%s\n' "$worker_replicas" >> "$KUSTOMIZE_LOG"
  orchestrator="${ORCHESTRATOR_IMAGE:-ghcr.io/example/orchestrator@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
  worker="${WORKER_IMAGE:-ghcr.io/example/worker@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}"
  autoscaler="${AUTOSCALER_IMAGE:-ghcr.io/example/autoscaler@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc}"
  printf '%s\n' \
    'apiVersion: apps/v1' \
    'kind: Deployment' \
    'metadata:' \
    '  name: symphony-orchestrator' \
    'spec:' \
    '  template:' \
    '    spec:' \
    '      containers:' \
    '        - name: orchestrator' \
    "          image: $orchestrator" \
    '---' \
    'apiVersion: apps/v1' \
    'kind: StatefulSet' \
    'metadata:' \
    '  name: symphony-worker' \
    'spec:' \
    '  template:' \
    '    spec:' \
    '      containers:' \
    '        - name: worker' \
    "          image: $worker" \
    '---' \
    'apiVersion: apps/v1' \
    'kind: Deployment' \
    'metadata:' \
    '  name: symphony-autoscaler' \
    'spec:' \
    '  template:' \
    '    spec:' \
    '      containers:' \
    '        - name: autoscaler' \
    "          image: $autoscaler"
fi
EOF
chmod +x "$TEMP_DIR/kustomize"

export KUBECTL_LOG="$TEMP_DIR/kubectl.log"
export DOCTL_LOG="$TEMP_DIR/doctl.log"
export KUSTOMIZE_LOG="$TEMP_DIR/kustomize.log"
export STATE_COUNT_FILE="$TEMP_DIR/state-count"

ORCHESTRATOR_IMAGE="ghcr.io/jasonmorganson/symphony-k8s-orchestrator@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
WORKER_IMAGE="ghcr.io/jasonmorganson/symphony-k8s-worker@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
AUTOSCALER_IMAGE="ghcr.io/jasonmorganson/symphony-k8s-autoscaler@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
SOURCE_REVISION="dddddddddddddddddddddddddddddddddddddddd"
export ORCHESTRATOR_IMAGE WORKER_IMAGE AUTOSCALER_IMAGE SOURCE_REVISION

reset_logs() {
  : > "$KUBECTL_LOG"
  : > "$DOCTL_LOG"
  : > "$KUSTOMIZE_LOG"
  rm -f "$STATE_COUNT_FILE"
}

run_deploy() {
  KUBECTL="$TEMP_DIR/kubectl" \
    KUSTOMIZE="$TEMP_DIR/kustomize" \
    DOCTL="$TEMP_DIR/doctl" \
    SYMPHONY_IDLE_POLL_SECONDS=0 \
    bash "$ROOT_DIR/scripts/deploy-digitalocean.sh"
}

reset_logs
DOKS_CLUSTER=production-cluster \
  SYMPHONY_SYSTEM_NODE_POOL=durable-system \
  SYMPHONY_WORKER_NODE_POOL=worker-pool \
  run_deploy

grep -F "get --raw /api/v1/namespaces/symphony/services/http:symphony-orchestrator:4000/proxy/api/v1/state" "$KUBECTL_LOG"
grep -F "kubernetes cluster node-pool update production-cluster worker-pool --auto-scale --min-nodes 0 --max-nodes 10" "$DOCTL_LOG"
grep -F "edit set image nscr.io/k7qcltdhpncg0/symphony-k8s/orchestrator=$ORCHESTRATOR_IMAGE" "$KUSTOMIZE_LOG"
grep -F "nscr.io/k7qcltdhpncg0/symphony-k8s/worker=$WORKER_IMAGE" "$KUSTOMIZE_LOG"
grep -F "ghcr.io/jasonmorganson/symphony-k8s-autoscaler=$AUTOSCALER_IMAGE" "$KUSTOMIZE_LOG"
grep -F "apply --dry-run=client -f " "$KUBECTL_LOG"
grep -F "apply -f " "$KUBECTL_LOG"
grep -F -- "-n symphony get statefulset symphony-worker -o jsonpath={.spec.replicas}" "$KUBECTL_LOG"
grep -F "build worker_replicas=2" "$KUSTOMIZE_LOG"
grep -F "annotate --overwrite deployment/symphony-orchestrator deployment/symphony-autoscaler statefulset/symphony-worker symphony.morganson.me/source-revision=$SOURCE_REVISION" "$KUBECTL_LOG"
grep -F -- "-n symphony rollout status deployment/symphony-orchestrator --timeout=10m" "$KUBECTL_LOG"
grep -F -- "-n symphony rollout status deployment/symphony-autoscaler --timeout=10m" "$KUBECTL_LOG"
grep -F -- "-n symphony get statefulset symphony-worker -o jsonpath=" "$KUBECTL_LOG"
for deployment in coredns konnectivity-agent hubble-relay hubble-ui; do
  grep -F -- "-n kube-system patch deployment $deployment --type=strategic" "$KUBECTL_LOG"
  grep -F -- "-n kube-system rollout status deployment/$deployment --timeout=5m" "$KUBECTL_LOG"
done
grep -F '"doks.digitalocean.com/node-pool":"durable-system"' "$KUBECTL_LOG"

reset_logs
WORKER_REPLICAS=7 run_deploy
grep -F "build worker_replicas=7" "$KUSTOMIZE_LOG"

reset_logs
DOKS_REFRESH_KUBECONFIG=true run_deploy
grep -F "kubernetes cluster kubeconfig save --expiry-seconds 600 symphony-k8s" "$DOCTL_LOG"
[[ "$(grep -Fc "kubernetes cluster kubeconfig save --expiry-seconds 600 symphony-k8s" "$DOCTL_LOG")" -ge 7 ]]

reset_logs
STATE_MODE=busy_then_idle run_deploy
[[ "$(grep -Fc "get --raw " "$KUBECTL_LOG")" == "2" ]]
grep -F "kubernetes cluster node-pool update symphony-k8s symphony-ha --auto-scale --min-nodes 0 --max-nodes 10" "$DOCTL_LOG"

reset_logs
if STATE_MODE=busy SYMPHONY_IDLE_TIMEOUT_SECONDS=0 run_deploy; then
  echo "busy Symphony must fail at the idle deadline" >&2
  exit 1
fi
[[ ! -s "$DOCTL_LOG" ]]
if grep -F "apply " "$KUBECTL_LOG"; then
  echo "busy Symphony must fail before applying resources" >&2
  exit 1
fi

for state_mode in invalid unavailable; do
  reset_logs
  if STATE_MODE="$state_mode" run_deploy; then
    echo "$state_mode Symphony state must fail closed" >&2
    exit 1
  fi
  [[ ! -s "$DOCTL_LOG" ]]
done

reset_logs
if MISSING_DEPLOYMENTS=coredns run_deploy; then
  echo "missing required deployment must fail preflight" >&2
  exit 1
fi
[[ ! -s "$DOCTL_LOG" ]]
if grep -F "apply " "$KUBECTL_LOG"; then
  echo "overlay must not be applied after failed preflight" >&2
  exit 1
fi

reset_logs
if API_ERROR_DEPLOYMENTS=hubble-relay run_deploy; then
  echo "optional deployment API errors must fail preflight" >&2
  exit 1
fi
[[ ! -s "$DOCTL_LOG" ]]

reset_logs
if KUSTOMIZE_ERROR=1 run_deploy; then
  echo "render errors must fail deployment" >&2
  exit 1
fi
[[ ! -s "$DOCTL_LOG" ]]
if grep -F "apply " "$KUBECTL_LOG"; then
  echo "render errors must fail before applying resources" >&2
  exit 1
fi

reset_logs
if DOCTL_ERROR=1 run_deploy; then
  echo "node-pool reconciliation errors must fail deployment" >&2
  exit 1
fi
if grep -F "apply -f " "$KUBECTL_LOG"; then
  echo "provider failure must occur before the real apply" >&2
  exit 1
fi

reset_logs
if SYMPHONY_WORKER_MIN_NODES=11 SYMPHONY_WORKER_MAX_NODES=10 run_deploy; then
  echo "invalid node-pool bounds must fail deployment" >&2
  exit 1
fi
[[ ! -s "$KUBECTL_LOG" && ! -s "$DOCTL_LOG" && ! -s "$KUSTOMIZE_LOG" ]]

reset_logs
saved_autoscaler="$AUTOSCALER_IMAGE"
unset AUTOSCALER_IMAGE
if run_deploy; then
  echo "partial image overrides must fail deployment" >&2
  exit 1
fi
export AUTOSCALER_IMAGE="$saved_autoscaler"
[[ ! -s "$KUBECTL_LOG" && ! -s "$DOCTL_LOG" ]]

reset_logs
if KUBECTL_FAIL_ROLLOUT=symphony-autoscaler run_deploy; then
  echo "failed workload rollout must fail deployment" >&2
  exit 1
fi
grep -F -- "-n symphony get deployment,statefulset,pods -o wide" "$KUBECTL_LOG"
grep -F -- "-n symphony describe deployment symphony-orchestrator" "$KUBECTL_LOG"
grep -F -- "-n symphony describe deployment symphony-autoscaler" "$KUBECTL_LOG"

echo "DOKS deployment tests passed"
