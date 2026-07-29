#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$ROOT_DIR/.github/workflows/publish-images.yml"
bake_file="$ROOT_DIR/docker-bake.hcl"

test_job="$(sed -n '/^  test:$/,/^  publish:$/p' "$workflow")"
publish_job="$(sed -n '/^  publish:$/,/^  deploy:$/p' "$workflow")"
deploy_job="$(sed -n '/^  deploy:$/,$p' "$workflow")"
control_plane_dockerfile="$ROOT_DIR/docker/control-plane/Dockerfile"
worker_dockerfile="$ROOT_DIR/docker/worker/Dockerfile"
autoscaler_dockerfile="$ROOT_DIR/docker/autoscaler/Dockerfile"

setup_buildx='docker/setup-buildx-action@8d2750c68a42422c14e847fe6c8ac0403b4cbd6f'
bake_action='docker/bake-action@d3418bd7d0e9324001bca92fa8ba175ea7e6dc9b'

[[ "$(grep -Fc "$setup_buildx" "$workflow")" -eq 2 ]]
[[ "$(grep -Fc "$bake_action" "$workflow")" -eq 2 ]]
grep -Fq 'needs: [classify, test, deployment-plan]' <<<"$publish_job"
grep -Fq "github.event_name != 'pull_request'" <<<"$publish_job"
grep -Fq \
  "|| 'production-doks'" "$workflow"
# GitHub expressions are intentionally matched as literal workflow text.
# shellcheck disable=SC2016
grep -Fq \
  'cancel-in-progress: ${{ github.event_name == '\''pull_request'\'' }}' \
  "$workflow"
[[ "$(grep -Fc 'load: true' "$workflow")" -eq 2 ]]
grep -Fq 'run: bash tests/test-image-pipeline.sh' <<<"$test_job"
grep -Fq "if: steps.image-targets.outputs.targets != ''" <<<"$test_job"
# shellcheck disable=SC2016
grep -Fq 'targets: ${{ steps.image-targets.outputs.targets }}' \
  <<<"$test_job"
grep -Fq "if: steps.publish-image-targets.outputs.targets != ''" \
  <<<"$publish_job"
# shellcheck disable=SC2016
grep -Fq \
  'targets: ${{ steps.publish-image-targets.outputs.targets }}' \
  <<<"$publish_job"
grep -Fq "if: needs.classify.outputs.worker == 'true'" <<<"$publish_job"

for target in runtime-base release orchestrator worker autoscaler; do
  grep -Fq "target \"$target\"" "$bake_file"
  grep -Fq \
    "cache-from = [\"type=gha,scope=symphony-$target\"]" \
    "$bake_file"
  if grep -Fq "$target.cache-to=" <<<"$test_job"; then
    echo "PR validation must read, but not export, the $target cache" >&2
    exit 1
  fi
  [[ "$(grep -Fc \
    "$target.cache-to=type=gha,mode=max,scope=symphony-$target" \
    <<<"$publish_job")" -eq 1 ]]
done

grep -Fq 'target "control-plane-build"' "$bake_file"
grep -Fq \
  'cache-from = ["type=gha,scope=symphony-control-plane-build"]' \
  "$bake_file"
if grep -Fq 'control-plane-build.cache-to=' <<<"$test_job"; then
  echo "PR validation must not export the shared control-plane cache" >&2
  exit 1
fi
[[ "$(grep -Fc \
  'control-plane-build.cache-to=type=gha,mode=max,scope=symphony-control-plane-build' \
  <<<"$publish_job")" -eq 1 ]]

[[ "$(grep -Fc '.cache-to=type=gha,mode=max,scope=' <<<"$test_job")" -eq 0 ]]
[[ "$(grep -Fc '.cache-to=type=gha,mode=max,scope=' <<<"$publish_job")" -eq 6 ]]

grep -Fq 'runtime-base = "target:runtime-base"' "$bake_file"
grep -Fq 'release      = "target:release"' "$bake_file"
grep -Fq 'RUNTIME_BASE           = "runtime-base"' "$bake_file"
grep -Fq 'SYMPHONY_RELEASE_IMAGE = "release"' "$bake_file"
[[ "$(grep -Fc 'control-plane-build = "target:control-plane-build"' "$bake_file")" -eq 2 ]]
[[ "$(grep -Fc 'CONTROL_PLANE_BUILD = "control-plane-build"' "$bake_file")" -eq 2 ]]
grep -Fq -- '--bin symphony-autoscaler' "$control_plane_dockerfile"
grep -Fq -- '--bin symphony-workspace-reclaimer' "$control_plane_dockerfile"
if grep -Fq 'cargo build' "$worker_dockerfile" ||
    grep -Fq 'cargo build' "$autoscaler_dockerfile"; then
  echo "final image Dockerfiles must reuse the shared control-plane build" >&2
  exit 1
fi
grep -Fq \
  'COPY --from=control-plane-build /src/target/release/symphony-workspace-reclaimer' \
  "$worker_dockerfile"
grep -Fq \
  'COPY --from=control-plane-build /src/target/release/symphony-autoscaler' \
  "$autoscaler_dockerfile"

grep -Fq 'runtime-base.tags=symphony-runtime-base:test' <<<"$test_job"
grep -Fq 'release.tags=symphony-release:test' <<<"$test_job"
grep -Fq 'orchestrator.tags=symphony-orchestrator:test' <<<"$test_job"
grep -Fq 'worker.tags=symphony-worker:test' <<<"$test_job"
grep -Fq 'autoscaler.tags=symphony-autoscaler:test' <<<"$test_job"

grep -Fq 'runtime-base.tags=symphony-runtime-base:do' <<<"$publish_job"
grep -Fq 'release.tags=symphony-release:do' <<<"$publish_job"
# GitHub expressions are intentionally matched as literal workflow text.
# shellcheck disable=SC2016
grep -Fq 'symphony-k8s-orchestrator:${{ github.sha }}' <<<"$publish_job"
# shellcheck disable=SC2016
grep -Fq 'symphony-k8s-worker:${{ github.sha }}' <<<"$publish_job"
grep -Fq 'symphony-k8s-worker:20260712-chatgpt' <<<"$publish_job"
# shellcheck disable=SC2016
grep -Fq 'symphony-k8s-autoscaler:${{ github.sha }}' <<<"$publish_job"
grep -Fq 'docker run --rm --entrypoint gh' <<<"$publish_job"

select_line="$(grep -n '^      - name: Select publish image targets$' \
  "$workflow" | cut -d: -f1)"
build_line="$(grep -n '^      - name: Build images$' "$workflow" | cut -d: -f1)"
verify_line="$(grep -n '^      - name: Verify worker image$' "$workflow" | cut -d: -f1)"
push_line="$(grep -n '^      - name: Push images$' "$workflow" | cut -d: -f1)"
digest_line="$(grep -n '^      - name: Resolve immutable image digests$' \
  "$workflow" | cut -d: -f1)"
(( select_line < build_line && build_line < verify_line &&
   verify_line < push_line && push_line < digest_line ))
# shellcheck disable=SC2016
grep -Fq \
  'docker push "ghcr.io/jasonmorganson/symphony-k8s-orchestrator:${GITHUB_SHA}"' \
  <<<"$publish_job"
# shellcheck disable=SC2016
grep -Fq \
  'docker push "ghcr.io/jasonmorganson/symphony-k8s-worker:${GITHUB_SHA}"' \
  <<<"$publish_job"
grep -Fq \
  'docker push ghcr.io/jasonmorganson/symphony-k8s-worker:20260712-chatgpt' \
  <<<"$publish_job"
# shellcheck disable=SC2016
grep -Fq \
  'docker push "ghcr.io/jasonmorganson/symphony-k8s-autoscaler:${GITHUB_SHA}"' \
  <<<"$publish_job"
[[ "$(grep -Fc 'docker buildx imagetools inspect' "$workflow")" -eq 3 ]]
# shellcheck disable=SC2016
grep -Fq \
  'orchestrator_image: ${{ steps.image-digests.outputs.orchestrator_image }}' \
  <<<"$publish_job"
# shellcheck disable=SC2016
grep -Fq \
  'worker_image: ${{ steps.image-digests.outputs.worker_image }}' \
  <<<"$publish_job"
# shellcheck disable=SC2016
grep -Fq \
  'autoscaler_image: ${{ steps.image-digests.outputs.autoscaler_image }}' \
  <<<"$publish_job"
# shellcheck disable=SC2016
grep -Fq \
  'ORCHESTRATOR_IMAGE: ${{ needs.publish.outputs.orchestrator_image }}' \
  <<<"$deploy_job"
# shellcheck disable=SC2016
grep -Fq \
  'WORKER_IMAGE: ${{ needs.publish.outputs.worker_image }}' \
  <<<"$deploy_job"
# shellcheck disable=SC2016
grep -Fq \
  'AUTOSCALER_IMAGE: ${{ needs.publish.outputs.autoscaler_image }}' \
  <<<"$deploy_job"

echo "image pipeline tests passed"
