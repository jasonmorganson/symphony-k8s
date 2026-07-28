#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECTL="${KUBECTL:-kubectl}"
KUSTOMIZE="${KUSTOMIZE:-kustomize}"
DOCTL="${DOCTL:-doctl}"
JQ="${JQ:-jq}"
DOKS_CLUSTER="${DOKS_CLUSTER:-symphony-k8s}"
SYSTEM_POOL="${SYMPHONY_SYSTEM_NODE_POOL:-symphony-system}"
WORKER_POOL="${SYMPHONY_WORKER_NODE_POOL:-symphony-ha}"
WORKER_MIN_NODES="${SYMPHONY_WORKER_MIN_NODES:-0}"
WORKER_MAX_NODES="${SYMPHONY_WORKER_MAX_NODES:-10}"
WORKER_VOLUME_SIZE="${SYMPHONY_WORKER_VOLUME_SIZE:-50Gi}"
DEPLOY_BOOTSTRAP_RUNTIME="${DEPLOY_BOOTSTRAP_RUNTIME:-false}"
DOKS_REFRESH_KUBECONFIG="${DOKS_REFRESH_KUBECONFIG:-false}"
SYMPHONY_WAIT_FOR_IDLE="${SYMPHONY_WAIT_FOR_IDLE:-true}"
SYMPHONY_IDLE_TIMEOUT_SECONDS="${SYMPHONY_IDLE_TIMEOUT_SECONDS:-3600}"
SYMPHONY_IDLE_POLL_SECONDS="${SYMPHONY_IDLE_POLL_SECONDS:-30}"
SYMPHONY_STATE_PATH="${SYMPHONY_STATE_PATH:-/api/v1/namespaces/symphony/services/http:symphony-orchestrator:4000/proxy/api/v1/state}"
SOURCE_REVISION="${SOURCE_REVISION:-}"
ORCHESTRATOR_IMAGE="${ORCHESTRATOR_IMAGE:-}"
WORKER_IMAGE="${WORKER_IMAGE:-}"
AUTOSCALER_IMAGE="${AUTOSCALER_IMAGE:-}"

TEMP_DIR=""
MUTATION_STARTED=0
QUIESCE_STARTED=0
ORIGINAL_AUTOSCALER_REPLICAS=""
ORIGINAL_DRAINS_JSON=""

emit_diagnostics() {
  if (( MUTATION_STARTED == 0 )); then
    return
  fi

  echo "deployment failed after mutation; collecting non-secret diagnostics" >&2
  "$KUBECTL" -n symphony get deployment,statefulset,pods -o wide >&2 || true
  "$KUBECTL" -n symphony describe deployment symphony-orchestrator >&2 || true
  "$KUBECTL" -n symphony describe deployment symphony-autoscaler >&2 || true
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if (( QUIESCE_STARTED == 1 )); then
    restore_symphony_admissions || status=1
  fi
  if (( status != 0 )); then
    emit_diagnostics
  fi
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  echo "$*" >&2
  return 1
}

require_boolean() {
  local name="$1"
  local value="$2"
  if [[ "$value" != "true" && "$value" != "false" ]]; then
    fail "$name must be true or false"
  fi
}

require_nonnegative_integer() {
  local name="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    fail "$name must be a non-negative integer"
  fi
}

require_storage_size() {
  local name="$1"
  local value="$2"
  if [[ ! "$value" =~ ^[1-9][0-9]*Gi$ ]]; then
    fail "$name must be a positive whole-Gi storage size"
  fi
}

reconcile_worker_volumes() {
  local replicas
  local ordinal
  replicas="$("$KUBECTL" -n symphony get statefulset symphony-worker \
    -o jsonpath='{.spec.replicas}')"
  require_nonnegative_integer "live Symphony worker replicas" "$replicas"
  for ((ordinal = 0; ordinal < replicas; ordinal++)); do
    "$KUBECTL" -n symphony patch \
      "persistentvolumeclaim/workspaces-symphony-worker-$ordinal" \
      --type=merge \
      --patch \
      '{"spec":{"resources":{"requests":{"storage":"'"$WORKER_VOLUME_SIZE"'"}}}}'
  done
}

validate_image() {
  local name="$1"
  local value="$2"
  local repository="$3"
  if [[ ! "$value" =~ ^${repository}@sha256:[0-9a-f]{64}$ ]]; then
    fail "$name must be an immutable $repository digest"
  fi
}

refresh_kubeconfig() {
  if [[ "$DOKS_REFRESH_KUBECONFIG" == "true" ]]; then
    "$DOCTL" kubernetes cluster kubeconfig save \
      --expiry-seconds 600 \
      "$DOKS_CLUSTER" >/dev/null
  fi
}

set_worker_drains() {
  local desired_drains_json="$1"
  local payload
  local response

  payload="$("$JQ" -cn --argjson hosts "$desired_drains_json" \
    '{drained_worker_hosts: $hosts}')"
  refresh_kubeconfig
  if ! response="$(printf '%s' "$payload" | "$KUBECTL" -n symphony exec \
    deployment/symphony-orchestrator -c orchestrator -i -- sh -c \
    'curl --fail --silent --show-error -X PUT \
      -H "Authorization: Bearer ${SYMPHONY_WORKER_DRAIN_TOKEN}" \
      -H "Content-Type: application/json" \
      --data-binary @- \
      http://127.0.0.1:4000/api/v1/worker-drains')"; then
    fail "unable to update Symphony worker drains"
  fi
  if ! printf '%s' "$response" | "$JQ" -e --argjson expected "$desired_drains_json" \
    '(.drained_hosts | sort) == ($expected | sort) and
      (.active_drained_hosts | type) == "array"' >/dev/null; then
    fail "invalid Symphony worker drain acknowledgement"
  fi
}

quiesce_symphony() {
  local state
  local configured_hosts_json

  refresh_kubeconfig
  state="$("$KUBECTL" get --raw "$SYMPHONY_STATE_PATH")"
  configured_hosts_json="$(printf '%s' "$state" | "$JQ" -ce \
    '.worker_pool.configured_hosts |
      if type == "array" and length == (unique | length) and
        all(.[]; type == "string" and length > 0)
      then . else error("invalid configured worker hosts") end')"
  ORIGINAL_DRAINS_JSON="$(printf '%s' "$state" | "$JQ" -ce \
    --argjson configured "$configured_hosts_json" \
    '.worker_pool.drained_hosts |
      if type == "array" and length == (unique | length) and
        all(.[]; . as $host |
        type == "string" and ($configured | index($host)) != null)
      then . else error("invalid drained worker hosts") end')"
  ORIGINAL_AUTOSCALER_REPLICAS="$("$KUBECTL" -n symphony get \
    deployment symphony-autoscaler -o jsonpath='{.spec.replicas}')"
  require_nonnegative_integer "live Symphony autoscaler replicas" \
    "$ORIGINAL_AUTOSCALER_REPLICAS"

  QUIESCE_STARTED=1
  MUTATION_STARTED=1
  set_worker_drains "$configured_hosts_json"
  refresh_kubeconfig
  "$KUBECTL" -n symphony scale deployment/symphony-autoscaler --replicas=0
  "$KUBECTL" -n symphony rollout status deployment/symphony-autoscaler --timeout=5m
  set_worker_drains "$configured_hosts_json"
}

restore_symphony_admissions() {
  local failed=0
  local drains_restored=0

  if (( QUIESCE_STARTED == 0 )); then
    return
  fi
  for _attempt in 1 2 3; do
    if set_worker_drains "$ORIGINAL_DRAINS_JSON"; then
      drains_restored=1
      break
    fi
    sleep 2
  done
  if (( drains_restored == 0 )); then
    failed=1
  fi
  refresh_kubeconfig || failed=1
  "$KUBECTL" -n symphony scale deployment/symphony-autoscaler \
    --replicas="$ORIGINAL_AUTOSCALER_REPLICAS" || failed=1
  if (( ORIGINAL_AUTOSCALER_REPLICAS > 0 )); then
    "$KUBECTL" -n symphony rollout status deployment/symphony-autoscaler \
      --timeout=10m || failed=1
  fi
  QUIESCE_STARTED=0
  if (( failed != 0 )); then
    fail "failed to restore Symphony admissions after deployment"
  fi
}

wait_for_symphony_state() {
  local require_idle="${1:-true}"
  local deadline=$((SECONDS + SYMPHONY_IDLE_TIMEOUT_SECONDS))
  local state
  local running_count
  local running_issues
  local demand_status

  require_boolean "Symphony idle requirement" "$require_idle"

  while true; do
    refresh_kubeconfig
    if ! state="$("$KUBECTL" get --raw "$SYMPHONY_STATE_PATH")"; then
      if (( SECONDS >= deadline )); then
        fail "Symphony state remained unavailable through the idle deadline"
      fi
      echo "waiting for Symphony state endpoint availability" >&2
      sleep "$SYMPHONY_IDLE_POLL_SECONDS"
      continue
    fi
    if ! running_count="$(printf '%s' "$state" | "$JQ" -er \
      'if (.running | type) == "array" then (.running | length) else error("running must be an array") end')"; then
      fail "invalid Symphony state; refusing to deploy"
    fi
    if ! demand_status="$(printf '%s' "$state" | "$JQ" -er \
      'if
         (.demand | type) == "object" and
         (.demand.eligible | type) == "number" and
         .demand.eligible >= 0 and
         .demand.observed_at == null
       then
         "uninitialized"
       elif
         (.demand | type) == "object" and
         (.demand.eligible | type) == "number" and
         .demand.eligible >= 0 and
         (.demand.observed_at | type) == "string" and
         (.demand.observed_at | length) > 0
       then
         "initialized"
       else
         error("invalid demand snapshot")
       end')"; then
      fail "invalid Symphony demand snapshot; refusing to deploy"
    fi
    if [[ "$demand_status" == "uninitialized" ]]; then
      if (( SECONDS >= deadline )); then
        fail "Symphony demand remained uninitialized through the idle deadline"
      fi
      echo "waiting for Symphony demand initialization" >&2
      sleep "$SYMPHONY_IDLE_POLL_SECONDS"
      continue
    fi
    if [[ "$require_idle" == "false" ]]; then
      echo "Symphony state is available; deployment may quiesce admissions"
      return
    fi
    if (( running_count == 0 )); then
      echo "Symphony is idle; deployment may proceed"
      return
    fi

    running_issues="$(printf '%s' "$state" | "$JQ" -r \
      '[.running[] | (.issue_identifier // .identifier // "unknown")] | join(",")')"
    if (( SECONDS >= deadline )); then
      fail "Symphony remained busy through the idle deadline: $running_issues"
    fi
    echo "waiting for active Symphony issues to finish: $running_issues" >&2
    sleep "$SYMPHONY_IDLE_POLL_SECONDS"
  done
}

validate_rendered_manifest() {
  local manifest="$1"

  if [[ "$DEPLOY_BOOTSTRAP_RUNTIME" == "false" ]] &&
      grep -Eq '^kind:[[:space:]]+Secret[[:space:]]*$' "$manifest"; then
    fail "CD manifest unexpectedly contains a Secret"
  fi
  if [[ "$DEPLOY_BOOTSTRAP_RUNTIME" == "false" ]] &&
      grep -Eq '^  name:[[:space:]]+symphony-workflow[[:space:]]*$' "$manifest"; then
    fail "CD manifest unexpectedly contains the runtime workflow ConfigMap"
  fi
  if (( image_override_count == 3 )); then
    for image in "$ORCHESTRATOR_IMAGE" "$WORKER_IMAGE" "$AUTOSCALER_IMAGE"; do
      if [[ "$(grep -Fc "image: $image" "$manifest")" -lt 1 ]]; then
        fail "rendered manifest must contain the workload image: $image"
      fi
    done
  fi
}

require_boolean DEPLOY_BOOTSTRAP_RUNTIME "$DEPLOY_BOOTSTRAP_RUNTIME"
require_boolean DOKS_REFRESH_KUBECONFIG "$DOKS_REFRESH_KUBECONFIG"
require_boolean SYMPHONY_WAIT_FOR_IDLE "$SYMPHONY_WAIT_FOR_IDLE"
require_nonnegative_integer SYMPHONY_WORKER_MIN_NODES "$WORKER_MIN_NODES"
require_nonnegative_integer SYMPHONY_WORKER_MAX_NODES "$WORKER_MAX_NODES"
require_storage_size SYMPHONY_WORKER_VOLUME_SIZE "$WORKER_VOLUME_SIZE"
require_nonnegative_integer SYMPHONY_IDLE_TIMEOUT_SECONDS "$SYMPHONY_IDLE_TIMEOUT_SECONDS"
require_nonnegative_integer SYMPHONY_IDLE_POLL_SECONDS "$SYMPHONY_IDLE_POLL_SECONDS"

if (( 10#$WORKER_MAX_NODES < 10#$WORKER_MIN_NODES )); then
  fail "invalid worker node-pool bounds: min=$WORKER_MIN_NODES max=$WORKER_MAX_NODES"
fi

image_override_count=0
for image in "$ORCHESTRATOR_IMAGE" "$WORKER_IMAGE" "$AUTOSCALER_IMAGE"; do
  if [[ -n "$image" ]]; then
    image_override_count=$((image_override_count + 1))
  fi
done
if (( image_override_count != 0 && image_override_count != 3 )); then
  fail "ORCHESTRATOR_IMAGE, WORKER_IMAGE, and AUTOSCALER_IMAGE must be set together"
fi
if (( image_override_count == 3 )); then
  validate_image ORCHESTRATOR_IMAGE "$ORCHESTRATOR_IMAGE" \
    "ghcr.io/jasonmorganson/symphony-k8s-orchestrator"
  validate_image WORKER_IMAGE "$WORKER_IMAGE" \
    "ghcr.io/jasonmorganson/symphony-k8s-worker"
  validate_image AUTOSCALER_IMAGE "$AUTOSCALER_IMAGE" \
    "ghcr.io/jasonmorganson/symphony-k8s-autoscaler"
fi
if [[ -n "$SOURCE_REVISION" && ! "$SOURCE_REVISION" =~ ^[0-9a-f]{40}$ ]]; then
  fail "SOURCE_REVISION must be a full Git commit SHA"
fi

refresh_kubeconfig

required_addons=(coredns konnectivity-agent)
optional_addons=(hubble-relay hubble-ui)
addons=()
live_worker_replicas=""

for deployment in "${required_addons[@]}"; do
  resource="$("$KUBECTL" -n kube-system get deployment "$deployment" --ignore-not-found -o name)"
  if [[ -z "$resource" ]]; then
    fail "required DOKS deployment is missing: $deployment"
  fi
  addons+=("$deployment")
done

for deployment in "${optional_addons[@]}"; do
  resource="$("$KUBECTL" -n kube-system get deployment "$deployment" --ignore-not-found -o name)"
  if [[ -n "$resource" ]]; then
    addons+=("$deployment")
  fi
done

if [[ "$DEPLOY_BOOTSTRAP_RUNTIME" == "false" ]]; then
  live_worker_replicas="$("$KUBECTL" -n symphony get statefulset symphony-worker \
    -o jsonpath='{.spec.replicas}')"
  require_nonnegative_integer "live Symphony worker replicas" "$live_worker_replicas"
fi

TEMP_DIR="$(mktemp -d)"
render_root="$TEMP_DIR/k8s"
cp -R "$ROOT_DIR/k8s" "$render_root"
render_target="$render_root/digitalocean"
if [[ "$DEPLOY_BOOTSTRAP_RUNTIME" == "true" ]]; then
  render_target="$render_root"
else
  worker_patch="$render_root/digitalocean/single-node-worker-patch.yaml"
  preserved_worker_patch="$TEMP_DIR/single-node-worker-patch.yaml"
  sed "s/^  replicas: [0-9][0-9]*$/  replicas: $live_worker_replicas/" \
    "$worker_patch" > "$preserved_worker_patch"
  mv "$preserved_worker_patch" "$worker_patch"
  if [[ "$(grep -Ec "^  replicas: $live_worker_replicas$" "$worker_patch")" != "1" ]]; then
    fail "unable to preserve live Symphony worker replicas"
  fi
fi

if (( image_override_count == 3 )); then
  (
    cd "$render_root/digitalocean"
    "$KUSTOMIZE" edit set image \
      "nscr.io/k7qcltdhpncg0/symphony-k8s/orchestrator=$ORCHESTRATOR_IMAGE" \
      "nscr.io/k7qcltdhpncg0/symphony-k8s/worker=$WORKER_IMAGE" \
      "ghcr.io/jasonmorganson/symphony-k8s-autoscaler=$AUTOSCALER_IMAGE"
  )
fi

rendered_manifest="$TEMP_DIR/rendered.yaml"
"$KUSTOMIZE" build "$render_target" > "$rendered_manifest"

validate_rendered_manifest "$rendered_manifest"

"$KUBECTL" apply --dry-run=client -f "$rendered_manifest" >/dev/null

if [[ "$SYMPHONY_WAIT_FOR_IDLE" == "true" ]] &&
    [[ "$DEPLOY_BOOTSTRAP_RUNTIME" == "false" ]]; then
  # Validate the state source before mutating admissions. Then quiesce first so
  # a continuous eligible backlog cannot replace completed sessions forever.
  # Existing sessions finish naturally while new dispatches remain drained.
  wait_for_symphony_state false
  quiesce_symphony
  wait_for_symphony_state true
  maintenance_autoscaler="$TEMP_DIR/autoscaler.yaml"
  sed '1,/^  replicas: 1$/ s/^  replicas: 1$/  replicas: 0/' \
    "$render_root/digitalocean/autoscaler.yaml" > "$maintenance_autoscaler"
  mv "$maintenance_autoscaler" "$render_root/digitalocean/autoscaler.yaml"
  if [[ "$(grep -Ec '^  replicas: 0$' \
    "$render_root/digitalocean/autoscaler.yaml")" != "1" ]]; then
    fail "unable to hold the Symphony autoscaler at zero during deployment"
  fi
  "$KUSTOMIZE" build "$render_target" > "$rendered_manifest"
  validate_rendered_manifest "$rendered_manifest"
  "$KUBECTL" apply --dry-run=client -f "$rendered_manifest" >/dev/null
fi

MUTATION_STARTED=1
"$DOCTL" kubernetes cluster node-pool update "$DOKS_CLUSTER" "$WORKER_POOL" \
  --auto-scale \
  --min-nodes "$WORKER_MIN_NODES" \
  --max-nodes "$WORKER_MAX_NODES"

"$KUBECTL" apply -f "$rendered_manifest"
reconcile_worker_volumes

if [[ -n "$SOURCE_REVISION" ]]; then
  "$KUBECTL" -n symphony annotate --overwrite \
    deployment/symphony-orchestrator \
    deployment/symphony-autoscaler \
    statefulset/symphony-worker \
    "symphony.morganson.me/source-revision=$SOURCE_REVISION"
fi

patch="$(printf '%s' \
  '{"spec":{"template":{"spec":{"nodeSelector":{"doks.digitalocean.com/node-pool":"'"$SYSTEM_POOL"'"},"tolerations":[{"key":"symphony.morganson.me/workload","operator":"Equal","value":"system","effect":"NoSchedule"}]}}}}')"

for deployment in "${addons[@]}"; do
  "$KUBECTL" -n kube-system patch deployment "$deployment" \
    --type=strategic --patch "$patch"
done

for deployment in "${addons[@]}"; do
  refresh_kubeconfig
  "$KUBECTL" -n kube-system rollout status "deployment/$deployment" --timeout=5m
done

refresh_kubeconfig
"$KUBECTL" -n symphony rollout status deployment/symphony-orchestrator --timeout=20m

if (( QUIESCE_STARTED == 1 )); then
  restore_symphony_admissions
else
  refresh_kubeconfig
  "$KUBECTL" -n symphony rollout status deployment/symphony-autoscaler --timeout=10m
fi

if (( image_override_count == 3 )); then
  deployed_worker_image="$("$KUBECTL" -n symphony get statefulset symphony-worker \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="worker")].image}')"
  if [[ "$deployed_worker_image" != "$WORKER_IMAGE" ]]; then
    fail "worker StatefulSet template does not contain the requested immutable image"
  fi
fi

echo "DOKS deployment completed successfully"
