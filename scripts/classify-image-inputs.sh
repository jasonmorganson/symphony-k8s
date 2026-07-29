#!/usr/bin/env bash
set -euo pipefail

# Classify the deployed-image input closure. Unknown paths deliberately rebuild
# every image: omitting a rebuild is safe only when this list proves the path
# cannot affect that image.
orchestrator=false
worker=false
autoscaler=false
reason=()

force_all() {
  orchestrator=true
  worker=true
  autoscaler=true
  reason+=("$1")
}

paths=("$@")
if (( ${#paths[@]} == 0 )); then
  force_all "empty change set"
fi

for path in "${paths[@]}"; do
  case "$path" in
    .dockerignore | docker-bake.hcl | skaffold.yaml | \
    .github/workflows/*)
      force_all "$path"
      ;;
    Cargo.lock | Cargo.toml | rust-toolchain.toml | rust/*)
      worker=true
      autoscaler=true
      reason+=("$path")
      ;;
    docker/control-plane/*)
      worker=true
      autoscaler=true
      reason+=("$path")
      ;;
    docker/runtime-base/* | docker/common/*)
      orchestrator=true
      worker=true
      reason+=("$path")
      ;;
    docker/release/* | docker/orchestrator/* | \
    config/workflow-runtime.yaml | config/workflow-throughput-overlay.md)
      orchestrator=true
      reason+=("$path")
      ;;
    docker/worker/* | config/sshd_config.d/*)
      worker=true
      reason+=("$path")
      ;;
    docker/autoscaler/*)
      autoscaler=true
      reason+=("$path")
      ;;
    README.md | .gitignore | k8s/* | tests/* | scripts/*)
      ;;
    *)
      force_all "unknown:$path"
      ;;
  esac
done

{
  echo "orchestrator=$orchestrator"
  echo "worker=$worker"
  echo "autoscaler=$autoscaler"
  printf 'reason=%s\n' "$(IFS=,; echo "${reason[*]:-no image inputs changed}")"
}
