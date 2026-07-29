#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

cat > "$TEMP_DIR/kubectl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KUBECTL_LOG"
printf 'kubectl:%s\n' "$*" >> "$EVENT_LOG"

if [[ "$*" == "get --raw "* ]]; then
  case "${STATE_MODE:-idle}" in
    idle)
      printf '{"running":[],"retrying":[],"demand":{"eligible":0,"observed_at":"2026-07-24T22:00:00Z"},"worker_pool":{"configured_hosts":["worker-0","worker-1"],"drained_hosts":%s}}\n' \
        "${INITIAL_DRAINS_JSON:-[]}"
      ;;
    busy)
      printf '%s\n' \
        '{"running":[{"issue_identifier":"A-230"}],"retrying":[],"demand":{"eligible":1,"observed_at":"2026-07-24T22:00:00Z"},"worker_pool":{"configured_hosts":["worker-0","worker-1"],"drained_hosts":[]}}'
      ;;
    busy_then_idle)
      count=0
      if [[ -f "$STATE_COUNT_FILE" ]]; then
        count="$(cat "$STATE_COUNT_FILE")"
      fi
      count=$((count + 1))
      printf '%s\n' "$count" > "$STATE_COUNT_FILE"
      if (( count == 1 )); then
        printf '%s\n' \
          '{"running":[{"issue_identifier":"A-230"}],"retrying":[],"demand":{"eligible":1,"observed_at":"2026-07-24T22:00:00Z"},"worker_pool":{"configured_hosts":["worker-0","worker-1"],"drained_hosts":["worker-1"]}}'
      else
        printf '%s\n' \
          '{"running":[],"retrying":[{"issue_identifier":"A-211"}],"demand":{"eligible":1,"observed_at":"2026-07-24T22:00:00Z"},"worker_pool":{"configured_hosts":["worker-0","worker-1"],"drained_hosts":["worker-1"]}}'
      fi
      ;;
    uninitialized)
      printf '%s\n' \
        '{"running":[],"retrying":[],"demand":{"eligible":0,"observed_at":null},"worker_pool":{"configured_hosts":["worker-0","worker-1"],"drained_hosts":[]}}'
      ;;
    uninitialized_then_idle)
      count=0
      if [[ -f "$STATE_COUNT_FILE" ]]; then
        count="$(cat "$STATE_COUNT_FILE")"
      fi
      count=$((count + 1))
      printf '%s\n' "$count" > "$STATE_COUNT_FILE"
      if (( count == 1 )); then
        printf '%s\n' \
          '{"running":[],"retrying":[],"demand":{"eligible":0,"observed_at":null},"worker_pool":{"configured_hosts":["worker-0","worker-1"],"drained_hosts":[]}}'
      else
        printf '{"running":[],"retrying":[],"demand":{"eligible":0,"observed_at":"2026-07-24T22:00:00Z"},"worker_pool":{"configured_hosts":["worker-0","worker-1"],"drained_hosts":%s}}\n' \
          "${INITIAL_DRAINS_JSON:-[]}"
      fi
      ;;
    invalid)
      printf '%s\n' '{"running":"not-an-array"}'
      ;;
    unavailable)
      exit 1
      ;;
    unavailable_then_idle)
      count=0
      if [[ -f "$STATE_COUNT_FILE" ]]; then
        count="$(cat "$STATE_COUNT_FILE")"
      fi
      count=$((count + 1))
      printf '%s\n' "$count" > "$STATE_COUNT_FILE"
      if (( count == 1 )); then
        exit 1
      fi
      printf '{"running":[],"retrying":[],"demand":{"eligible":0,"observed_at":"2026-07-24T22:00:00Z"},"worker_pool":{"configured_hosts":["worker-0","worker-1"],"drained_hosts":%s}}\n' \
        "${INITIAL_DRAINS_JSON:-[]}"
      ;;
  esac
  exit 0
fi

if [[ "$*" == *"-n symphony get deployment symphony-autoscaler "* ]] &&
    [[ "$*" == *"jsonpath={.spec.replicas}"* ]]; then
  printf '%s' "${AUTOSCALER_REPLICAS:-1}"
  exit 0
fi

if [[ "$*" == *"-n symphony get deployment symphony-orchestrator "* ]] &&
    [[ "$*" == *'containers[?(@.name=="orchestrator")].image'* ]]; then
  printf '%s' "${ORCHESTRATOR_DEPLOYED_IMAGE:-$ORCHESTRATOR_IMAGE}"
  exit 0
fi

if [[ "$*" == *"-n symphony get deployment symphony-autoscaler "* ]] &&
    [[ "$*" == *'containers[?(@.name=="autoscaler")].image'* ]]; then
  printf '%s' "${AUTOSCALER_DEPLOYED_IMAGE:-$AUTOSCALER_IMAGE}"
  exit 0
fi

if [[ "$*" == *"-n symphony get "*"source-revision"* ]]; then
  printf '%s' "${DEPLOYED_SOURCE_REVISION:-$SOURCE_REVISION}"
  exit 0
fi

if [[ "$*" == *"-n symphony get pods -l app=symphony-orchestrator -o json"* ]]; then
  image="${ORCHESTRATOR_RUNTIME_IMAGE:-$ORCHESTRATOR_IMAGE}"
  digest="${image##*@}"
  jq -cn --arg image "$image" --arg digest "$digest" '
    {items: [{
      metadata: {name: "symphony-orchestrator-0"},
      spec: {containers: [{name: "orchestrator", image: $image}]},
      status: {
        conditions: [{type: "Ready", status: "True"}],
        containerStatuses: [{
          name: "orchestrator",
          ready: true,
          imageID: ("docker-pullable://orchestrator@" + $digest)
        }]
      }
    }]}'
  exit 0
fi

if [[ "$*" == *"-n symphony get pods -l app=symphony-autoscaler -o json"* ]]; then
  image="${AUTOSCALER_RUNTIME_IMAGE:-$AUTOSCALER_IMAGE}"
  digest="${image##*@}"
  replicas="${AUTOSCALER_REPLICAS:-1}"
  jq -cn --arg image "$image" --arg digest "$digest" --argjson replicas "$replicas" '
    {items: [range(0; $replicas) | {
      metadata: {name: ("symphony-autoscaler-" + (. | tostring))},
      spec: {containers: [{name: "autoscaler", image: $image}]},
      status: {
        conditions: [{type: "Ready", status: "True"}],
        containerStatuses: [{
          name: "autoscaler",
          ready: true,
          imageID: ("docker-pullable://autoscaler@" + $digest)
        }]
      }
    }]}'
  exit 0
fi

if [[ "$*" == *"-n symphony get pods -l app=symphony-worker -o json"* ]]; then
  image="${WORKER_RUNTIME_IMAGE:-$WORKER_IMAGE}"
  digest="${image##*@}"
  replicas="${WORKER_REPLICAS:-2}"
  jq -cn --arg image "$image" --arg digest "$digest" --argjson replicas "$replicas" '
    {items: [range(0; $replicas) | {
      metadata: {name: ("symphony-worker-" + (. | tostring))},
      spec: {containers: [
        {name: "worker", image: $image},
        {name: "workspace-reclaimer", image: $image}
      ]},
      status: {
        conditions: [{type: "Ready", status: "True"}],
        containerStatuses: [
          {
            name: "worker",
            ready: true,
            imageID: ("docker-pullable://worker@" + $digest)
          },
          {
            name: "workspace-reclaimer",
            ready: true,
            imageID: ("docker-pullable://worker@" + $digest)
          }
        ]
      }
    }]}'
  exit 0
fi

if [[ "$*" == *"-n symphony exec deployment/symphony-orchestrator "* ]]; then
  payload="$(cat)"
  printf '%s\n' "$payload" >> "$DRAIN_LOG"
  desired="$(printf '%s' "$payload" | jq -c '.drained_worker_hosts')"
  printf 'drain:%s\n' "$desired" >> "$EVENT_LOG"
  drain_count=0
  if [[ -f "$DRAIN_COUNT_FILE" ]]; then
    drain_count="$(cat "$DRAIN_COUNT_FILE")"
  fi
  drain_count=$((drain_count + 1))
  printf '%s\n' "$drain_count" > "$DRAIN_COUNT_FILE"
  if [[ "${DRAIN_FAIL_AT:-0}" == "$drain_count" ]]; then
    exit 1
  fi
  if [[ "${DRAIN_ACK_INVALID:-0}" == "1" ]]; then
    desired='["unexpected-worker"]'
  fi
  printf '{"drained_hosts":%s,"active_drained_hosts":[]}\n' "$desired"
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

if [[ "$*" == *" get statefulset symphony-worker "* ]] &&
    [[ "$*" == *'containers[?(@.name=="worker")].image'* ]]; then
  printf '%s' "${WORKER_DEPLOYED_IMAGE:-$WORKER_IMAGE}"
  exit 0
fi

if [[ "$*" == *" get statefulset symphony-worker "* ]] &&
    [[ "$*" == *'containers[?(@.name=="workspace-reclaimer")].image'* ]]; then
  printf '%s' "${WORKER_DEPLOYED_IMAGE:-$WORKER_IMAGE}"
  exit 0
fi

if [[ " $* " == *" apply -f "* ]] && [[ "${KUBECTL_FAIL_APPLY:-0}" == "1" ]]; then
  exit 1
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
  worker_patch="$2/single-node-worker-patch.yaml"
  autoscaler_manifest="$2/autoscaler.yaml"
  if [[ ! -f "$worker_patch" ]]; then
    worker_patch="$2/digitalocean/single-node-worker-patch.yaml"
  fi
  if [[ ! -f "$autoscaler_manifest" ]]; then
    autoscaler_manifest="$2/digitalocean/autoscaler.yaml"
  fi
  worker_replicas="$(awk '/^  replicas: / { print $2; exit }' "$worker_patch")"
  printf 'build worker_replicas=%s\n' "$worker_replicas" >> "$KUSTOMIZE_LOG"
  orchestrator="${ORCHESTRATOR_IMAGE:-ghcr.io/example/orchestrator@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
  worker="${WORKER_IMAGE:-ghcr.io/example/worker@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}"
  autoscaler="${AUTOSCALER_IMAGE:-ghcr.io/example/autoscaler@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc}"
  autoscaler_replicas="$(awk '
    /^kind: Deployment$/ { deployment = 1; next }
    deployment && /^  name: symphony-autoscaler$/ { autoscaler = 1; next }
    autoscaler && /^  replicas: / { print $2; exit }
  ' "$autoscaler_manifest")"
  printf 'build autoscaler_replicas=%s\n' \
    "${autoscaler_replicas:-1}" >> "$KUSTOMIZE_LOG"
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
    '        - name: workspace-reclaimer' \
    "          image: $worker" \
    '---' \
    'apiVersion: apps/v1' \
    'kind: Deployment' \
    'metadata:' \
    '  name: symphony-autoscaler' \
    'spec:' \
    "  replicas: ${autoscaler_replicas:-1}" \
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
export DRAIN_LOG="$TEMP_DIR/drain.log"
export EVENT_LOG="$TEMP_DIR/event.log"
export DRAIN_COUNT_FILE="$TEMP_DIR/drain-count"
export SYMPHONY_WORKER_DRAIN_TOKEN="sentinel-drain-token-that-must-not-appear"
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
  : > "$DRAIN_LOG"
  : > "$EVENT_LOG"
  rm -f "$STATE_COUNT_FILE"
  rm -f "$DRAIN_COUNT_FILE"
}

assert_restored() {
  local expected_drains="${1:-[]}"
  local expected_replicas="${2:-1}"

  jq -se --argjson expected "$expected_drains" \
    '.[-1].drained_worker_hosts == $expected' "$DRAIN_LOG" >/dev/null
  grep -F -- "-n symphony scale deployment/symphony-autoscaler --replicas=$expected_replicas" \
    "$KUBECTL_LOG" >/dev/null
}

assert_quiesced() {
  jq -se \
    '.[-1].drained_worker_hosts == ["worker-0", "worker-1"]' \
    "$DRAIN_LOG" >/dev/null
  if grep -F -- \
      "-n symphony scale deployment/symphony-autoscaler --replicas=1" \
      "$KUBECTL_LOG"; then
    echo "failed rollout must not restore autoscaler admissions" >&2
    exit 1
  fi
}

run_deploy() {
  local wait_for_idle="${SYMPHONY_WAIT_FOR_IDLE:-true}"
  KUBECTL="$TEMP_DIR/kubectl" \
    KUSTOMIZE="$TEMP_DIR/kustomize" \
    DOCTL="$TEMP_DIR/doctl" \
    SYMPHONY_WAIT_FOR_IDLE="$wait_for_idle" \
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
grep -F -- "-n symphony patch persistentvolumeclaim/workspaces-symphony-worker-0 --type=merge --patch {\"spec\":{\"resources\":{\"requests\":{\"storage\":\"50Gi\"}}}}" "$KUBECTL_LOG"
grep -F -- "-n symphony patch persistentvolumeclaim/workspaces-symphony-worker-1 --type=merge --patch {\"spec\":{\"resources\":{\"requests\":{\"storage\":\"50Gi\"}}}}" "$KUBECTL_LOG"
grep -F -- "-n symphony get statefulset symphony-worker -o jsonpath={.spec.replicas}" "$KUBECTL_LOG"
grep -F "build worker_replicas=2" "$KUSTOMIZE_LOG"
grep -F "build autoscaler_replicas=0" "$KUSTOMIZE_LOG"
jq -se '
  length == 4 and
  .[0].drained_worker_hosts == ["worker-0", "worker-1"] and
  .[1].drained_worker_hosts == ["worker-0", "worker-1"] and
  .[2].drained_worker_hosts == ["worker-0", "worker-1"] and
  .[3].drained_worker_hosts == []
' "$DRAIN_LOG" >/dev/null
scale_down_line="$(grep -nF -- \
  '-n symphony scale deployment/symphony-autoscaler --replicas=0' \
  "$KUBECTL_LOG" | head -1 | cut -d: -f1)"
apply_line="$(grep -nF 'apply -f ' "$KUBECTL_LOG" | head -1 | cut -d: -f1)"
restore_line="$(grep -nF -- \
  '-n symphony scale deployment/symphony-autoscaler --replicas=1' \
  "$KUBECTL_LOG" | tail -1 | cut -d: -f1)"
(( scale_down_line < apply_line && apply_line < restore_line ))
first_drain_line="$(grep -nF 'drain:["worker-0","worker-1"]' \
  "$EVENT_LOG" | head -1 | cut -d: -f1)"
first_idle_poll_line="$(grep -nF 'kubectl:get --raw ' "$EVENT_LOG" |
  head -1 | cut -d: -f1)"
scale_down_event_line="$(grep -nF \
  'kubectl:-n symphony scale deployment/symphony-autoscaler --replicas=0' \
  "$EVENT_LOG" | head -1 | cut -d: -f1)"
scale_down_ready_line="$(grep -nF \
  'kubectl:-n symphony rollout status deployment/symphony-autoscaler --timeout=5m' \
  "$EVENT_LOG" | head -1 | cut -d: -f1)"
second_drain_line="$(grep -nF 'drain:["worker-0","worker-1"]' \
  "$EVENT_LOG" | sed -n '2p' | cut -d: -f1)"
post_quiesce_idle_poll_line="$(grep -nF 'kubectl:get --raw ' "$EVENT_LOG" |
  tail -1 | cut -d: -f1)"
apply_event_line="$(grep -nF 'kubectl:apply -f ' "$EVENT_LOG" |
  head -1 | cut -d: -f1)"
restore_drain_line="$(grep -nF 'drain:[]' "$EVENT_LOG" |
  tail -1 | cut -d: -f1)"
post_restart_drain_line="$(grep -nF 'drain:["worker-0","worker-1"]' \
  "$EVENT_LOG" | tail -1 | cut -d: -f1)"
first_worker_delete_line="$(grep -nF \
  'kubectl:-n symphony delete pod/symphony-worker-1 --wait=true --timeout=5m' \
  "$EVENT_LOG" | head -1 | cut -d: -f1)"
(( first_idle_poll_line < first_drain_line &&
   first_drain_line < scale_down_event_line &&
   scale_down_event_line < scale_down_ready_line &&
   scale_down_ready_line < second_drain_line &&
   second_drain_line < post_quiesce_idle_poll_line &&
   post_quiesce_idle_poll_line < apply_event_line &&
   apply_event_line < post_restart_drain_line &&
   post_restart_drain_line < first_worker_delete_line &&
   first_worker_delete_line < restore_drain_line ))
grep -F "annotate --overwrite deployment/symphony-orchestrator deployment/symphony-autoscaler statefulset/symphony-worker symphony.morganson.me/source-revision=$SOURCE_REVISION" "$KUBECTL_LOG"
grep -F -- "-n symphony rollout status deployment/symphony-orchestrator --timeout=20m" "$KUBECTL_LOG"
grep -F -- "-n symphony rollout status deployment/symphony-autoscaler --timeout=10m" "$KUBECTL_LOG"
grep -F -- "-n symphony get statefulset symphony-worker -o jsonpath=" "$KUBECTL_LOG"
grep -F -- "-n symphony delete pod/symphony-worker-1 --wait=true --timeout=5m" "$KUBECTL_LOG"
grep -F -- "-n symphony wait --for=condition=Ready pod/symphony-worker-1 --timeout=20m" "$KUBECTL_LOG"
grep -F -- "-n symphony delete pod/symphony-worker-0 --wait=true --timeout=5m" "$KUBECTL_LOG"
grep -F -- "-n symphony wait --for=condition=Ready pod/symphony-worker-0 --timeout=20m" "$KUBECTL_LOG"
grep -F -- "-n symphony get pods -l app=symphony-orchestrator -o json" "$KUBECTL_LOG"
grep -F -- "-n symphony get pods -l app=symphony-worker -o json" "$KUBECTL_LOG"
grep -F -- "-n symphony get pods -l app=symphony-autoscaler -o json" "$KUBECTL_LOG"
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
[[ "$(grep -Fc "get --raw " "$KUBECTL_LOG")" == "3" ]]
jq -se '.[-1].drained_worker_hosts == ["worker-1"]' "$DRAIN_LOG" >/dev/null
grep -F "kubernetes cluster node-pool update symphony-k8s symphony-ha --auto-scale --min-nodes 0 --max-nodes 10" "$DOCTL_LOG"

reset_logs
STATE_MODE=busy SYMPHONY_WAIT_FOR_IDLE=false run_deploy
[[ "$(grep -Fc "get --raw " "$KUBECTL_LOG")" == "2" ]]
grep -F "apply -f " "$KUBECTL_LOG" >/dev/null

reset_logs
STATE_MODE=uninitialized_then_idle run_deploy
[[ "$(grep -Fc "get --raw " "$KUBECTL_LOG")" == "4" ]]
grep -F "apply -f " "$KUBECTL_LOG" >/dev/null

reset_logs
STATE_MODE=unavailable_then_idle run_deploy
[[ "$(grep -Fc "get --raw " "$KUBECTL_LOG")" == "4" ]]
grep -F "apply -f " "$KUBECTL_LOG" >/dev/null

reset_logs
if STATE_MODE=busy SYMPHONY_IDLE_TIMEOUT_SECONDS=0 run_deploy; then
  echo "busy Symphony must fail at the idle deadline" >&2
  exit 1
fi
[[ ! -s "$DOCTL_LOG" ]]
assert_restored
jq -se '
  .[0].drained_worker_hosts == ["worker-0", "worker-1"] and
  .[-1].drained_worker_hosts == []
' "$DRAIN_LOG" >/dev/null
if grep -F "apply -f " "$KUBECTL_LOG"; then
  echo "busy Symphony must fail before applying resources" >&2
  exit 1
fi

reset_logs
if STATE_MODE=invalid run_deploy; then
  echo "invalid Symphony state must fail closed" >&2
  exit 1
fi
[[ ! -s "$DOCTL_LOG" ]]
if grep -F "scale deployment/symphony-autoscaler" "$KUBECTL_LOG"; then
  echo "invalid Symphony state must not change autoscaler state" >&2
  exit 1
fi
if grep -F "apply -f " "$KUBECTL_LOG"; then
  echo "invalid Symphony state must fail before applying resources" >&2
  exit 1
fi

reset_logs
if STATE_MODE=unavailable SYMPHONY_IDLE_TIMEOUT_SECONDS=0 run_deploy; then
  echo "unavailable Symphony state must fail closed at the idle deadline" >&2
  exit 1
fi
[[ ! -s "$DOCTL_LOG" ]]
if grep -F "scale deployment/symphony-autoscaler" "$KUBECTL_LOG" ||
    grep -F "apply -f " "$KUBECTL_LOG"; then
  echo "unavailable Symphony state must not mutate provider or cluster state" >&2
  exit 1
fi

reset_logs
if STATE_MODE=uninitialized SYMPHONY_IDLE_TIMEOUT_SECONDS=0 run_deploy; then
  echo "persistently uninitialized Symphony demand must fail at the idle deadline" >&2
  exit 1
fi
[[ ! -s "$DOCTL_LOG" ]]
if grep -F "scale deployment/symphony-autoscaler" "$KUBECTL_LOG" ||
    grep -F "apply -f " "$KUBECTL_LOG"; then
  echo "uninitialized Symphony demand must not mutate provider or cluster state" >&2
  exit 1
fi

reset_logs
if DRAIN_ACK_INVALID=1 run_deploy; then
  echo "invalid drain acknowledgement must fail closed" >&2
  exit 1
fi
[[ ! -s "$DOCTL_LOG" ]]
if grep -F "apply -f " "$KUBECTL_LOG"; then
  echo "invalid drain acknowledgement must fail before applying resources" >&2
  exit 1
fi

reset_logs
if MISSING_DEPLOYMENTS=coredns run_deploy; then
  echo "missing required deployment must fail preflight" >&2
  exit 1
fi
[[ ! -s "$DOCTL_LOG" ]]
if grep -F "apply -f " "$KUBECTL_LOG"; then
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
if grep -F "apply -f " "$KUBECTL_LOG"; then
  echo "render errors must fail before applying resources" >&2
  exit 1
fi

reset_logs
if DOCTL_ERROR=1 run_deploy; then
  echo "node-pool reconciliation errors must fail deployment" >&2
  exit 1
fi
assert_restored
if grep -F "apply -f " "$KUBECTL_LOG"; then
  echo "provider failure must occur before the real apply" >&2
  exit 1
fi

reset_logs
if KUBECTL_FAIL_APPLY=1 run_deploy; then
  echo "apply failure must fail deployment" >&2
  exit 1
fi
assert_quiesced

reset_logs
if KUBECTL_FAIL_ROLLOUT=symphony-orchestrator run_deploy; then
  echo "orchestrator rollout failure must fail deployment" >&2
  exit 1
fi
assert_quiesced

reset_logs
wrong_worker_image="ghcr.io/jasonmorganson/symphony-k8s-worker@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
if WORKER_DEPLOYED_IMAGE="$wrong_worker_image" run_deploy; then
  echo "worker verification failure must fail deployment" >&2
  exit 1
fi
assert_quiesced

reset_logs
DRAIN_FAIL_AT=4 run_deploy
[[ "$(wc -l < "$DRAIN_LOG" | tr -d ' ')" == "5" ]]
assert_restored

reset_logs
INITIAL_DRAINS_JSON='["worker-1"]' AUTOSCALER_REPLICAS=2 run_deploy
assert_restored '["worker-1"]' 2

reset_logs
DEPLOY_BOOTSTRAP_RUNTIME=true run_deploy
if grep -F "get --raw " "$KUBECTL_LOG" ||
    grep -F "worker-drains" "$KUBECTL_LOG" ||
    grep -F "scale deployment/symphony-autoscaler --replicas=0" "$KUBECTL_LOG"; then
  echo "bootstrap deployment must skip runtime quiescing" >&2
  exit 1
fi

reset_logs
if SYMPHONY_WORKER_MIN_NODES=11 SYMPHONY_WORKER_MAX_NODES=10 run_deploy; then
  echo "invalid node-pool bounds must fail deployment" >&2
  exit 1
fi
[[ ! -s "$KUBECTL_LOG" && ! -s "$DOCTL_LOG" && ! -s "$KUSTOMIZE_LOG" ]]

reset_logs
if SYMPHONY_WORKER_VOLUME_SIZE=50G run_deploy; then
  echo "invalid worker volume size must fail deployment" >&2
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

if grep -R -F "$SYMPHONY_WORKER_DRAIN_TOKEN" "$TEMP_DIR"; then
  echo "deployment diagnostics must not expose the worker drain token" >&2
  exit 1
fi

echo "DOKS deployment tests passed"
