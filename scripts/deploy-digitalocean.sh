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
  trap - EXIT
  if (( status != 0 )); then
    emit_diagnostics
  fi
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
  exit "$status"
}
trap cleanup EXIT

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

wait_for_symphony_idle() {
  local deadline=$((SECONDS + SYMPHONY_IDLE_TIMEOUT_SECONDS))
  local state
  local running_count
  local running_issues

  while true; do
    refresh_kubeconfig
    if ! state="$("$KUBECTL" get --raw "$SYMPHONY_STATE_PATH")"; then
      fail "unable to read Symphony state; refusing to deploy"
    fi
    if ! running_count="$(printf '%s' "$state" | "$JQ" -er \
      'if (.running | type) == "array" then (.running | length) else error("running must be an array") end')"; then
      fail "invalid Symphony state; refusing to deploy"
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

require_boolean DEPLOY_BOOTSTRAP_RUNTIME "$DEPLOY_BOOTSTRAP_RUNTIME"
require_boolean DOKS_REFRESH_KUBECONFIG "$DOKS_REFRESH_KUBECONFIG"
require_boolean SYMPHONY_WAIT_FOR_IDLE "$SYMPHONY_WAIT_FOR_IDLE"
require_nonnegative_integer SYMPHONY_WORKER_MIN_NODES "$WORKER_MIN_NODES"
require_nonnegative_integer SYMPHONY_WORKER_MAX_NODES "$WORKER_MAX_NODES"
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

if [[ "$SYMPHONY_WAIT_FOR_IDLE" == "true" ]]; then
  wait_for_symphony_idle
fi
refresh_kubeconfig

required_addons=(coredns konnectivity-agent)
optional_addons=(hubble-relay hubble-ui)
addons=()

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

TEMP_DIR="$(mktemp -d)"
render_root="$TEMP_DIR/k8s"
cp -R "$ROOT_DIR/k8s" "$render_root"
render_target="$render_root/digitalocean"
if [[ "$DEPLOY_BOOTSTRAP_RUNTIME" == "true" ]]; then
  render_target="$render_root"
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

if [[ "$DEPLOY_BOOTSTRAP_RUNTIME" == "false" ]] &&
    grep -Eq '^kind:[[:space:]]+Secret[[:space:]]*$' "$rendered_manifest"; then
  fail "CD manifest unexpectedly contains a Secret"
fi
if [[ "$DEPLOY_BOOTSTRAP_RUNTIME" == "false" ]] &&
    grep -Eq '^  name:[[:space:]]+symphony-workflow[[:space:]]*$' "$rendered_manifest"; then
  fail "CD manifest unexpectedly contains the runtime workflow ConfigMap"
fi

if (( image_override_count == 3 )); then
  for image in "$ORCHESTRATOR_IMAGE" "$WORKER_IMAGE" "$AUTOSCALER_IMAGE"; do
    if [[ "$(grep -Fc "image: $image" "$rendered_manifest")" != "1" ]]; then
      fail "rendered manifest must contain exactly one workload image: $image"
    fi
  done
fi

"$KUBECTL" apply --dry-run=client -f "$rendered_manifest" >/dev/null

MUTATION_STARTED=1
"$DOCTL" kubernetes cluster node-pool update "$DOKS_CLUSTER" "$WORKER_POOL" \
  --auto-scale \
  --min-nodes "$WORKER_MIN_NODES" \
  --max-nodes "$WORKER_MAX_NODES"

"$KUBECTL" apply -f "$rendered_manifest"

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
"$KUBECTL" -n symphony rollout status deployment/symphony-orchestrator --timeout=10m
refresh_kubeconfig
"$KUBECTL" -n symphony rollout status deployment/symphony-autoscaler --timeout=10m

if (( image_override_count == 3 )); then
  deployed_worker_image="$("$KUBECTL" -n symphony get statefulset symphony-worker \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="worker")].image}')"
  if [[ "$deployed_worker_image" != "$WORKER_IMAGE" ]]; then
    fail "worker StatefulSet template does not contain the requested immutable image"
  fi
fi

echo "DOKS deployment completed successfully"
