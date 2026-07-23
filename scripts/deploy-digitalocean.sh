#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBECTL="${KUBECTL:-kubectl}"
KUSTOMIZE="${KUSTOMIZE:-kubectl}"
IMAGE_INSPECTOR="${SYMPHONY_IMAGE_INSPECTOR:-docker}"
SYSTEM_POOL="${SYMPHONY_SYSTEM_NODE_POOL:-symphony-system}"

if [[ "$(git -C "$ROOT_DIR" branch --show-current)" != "master" ]]; then
  echo "symphony-k8s deployment source must be checked out on master" >&2
  exit 1
fi
if [[ -n "$(git -C "$ROOT_DIR" status --porcelain=v1)" ]]; then
  echo "symphony-k8s deployment source must be clean" >&2
  exit 1
fi
git -C "$ROOT_DIR" fetch origin master --quiet
if [[ "$(git -C "$ROOT_DIR" rev-parse HEAD)" != \
      "$(git -C "$ROOT_DIR" rev-parse origin/master)" ]]; then
  echo "symphony-k8s deployment source is stale relative to origin/master" >&2
  exit 1
fi
symphony_revision="$(git -C "$ROOT_DIR" rev-parse HEAD)"
autoscaler_repository="ghcr.io/jasonmorganson/symphony-k8s-autoscaler"
autoscaler_digest="$(
  "$IMAGE_INSPECTOR" buildx imagetools inspect \
    "$autoscaler_repository:$symphony_revision" \
    --format '{{json .Manifest.Digest}}' | tr -d '"'
)"
if [[ ! "$autoscaler_digest" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "merged master autoscaler image has no valid immutable digest" >&2
  exit 1
fi
AUTOSCALER_IMAGE="$autoscaler_repository@$autoscaler_digest"

required_addons=(coredns konnectivity-agent)
optional_addons=(hubble-relay hubble-ui)
addons=()

SYMPHONY_REQUIRE_CLEAN_MAIN_SOURCE=1 \
  bash "$ROOT_DIR/scripts/generate-skaffold-inputs.sh"

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

rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT
"$KUSTOMIZE" kustomize "$ROOT_DIR/k8s/digitalocean" > "$rendered"
if [[ "$(grep -c 'image: ghcr.io/jasonmorganson/symphony-k8s-autoscaler@sha256:' "$rendered")" != "1" ]]; then
  echo "rendered deployment must contain exactly one autoscaler image" >&2
  exit 1
fi
AUTOSCALER_IMAGE="$AUTOSCALER_IMAGE" perl -0pi -e \
  's|image: ghcr\.io/jasonmorganson/symphony-k8s-autoscaler\@sha256:[0-9a-f]{64}|image: $ENV{AUTOSCALER_IMAGE}|g' \
  "$rendered"
"$KUBECTL" apply -f "$rendered"

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
