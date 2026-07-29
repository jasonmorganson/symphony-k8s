#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLASSIFIER="$ROOT_DIR/scripts/classify-image-inputs.sh"
DEPLOYMENT_CLASSIFIER="$ROOT_DIR/scripts/classify-deployment-images.sh"
VERIFY_DIGEST="$ROOT_DIR/scripts/verify-image-digest.sh"
WORKFLOW="$ROOT_DIR/.github/workflows/publish-images.yml"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

assert_flags() {
  local expected="$1"
  shift
  local actual
  actual="$("$CLASSIFIER" "$@" | sed -n '1,3p' | paste -sd ' ' -)"
  if [[ "$actual" != "$expected" ]]; then
    echo "unexpected classification for: $*" >&2
    echo "expected: $expected" >&2
    echo "actual:   $actual" >&2
    exit 1
  fi
}

all_true="orchestrator=true worker=true autoscaler=true"

assert_flags "$all_true"
assert_flags "$all_true" .dockerignore
assert_flags "$all_true" docker-bake.hcl
assert_flags "$all_true" .github/workflows/publish-images.yml
assert_flags "$all_true" unknown/new-shared-input

assert_flags \
  "orchestrator=false worker=true autoscaler=true" \
  Cargo.lock rust/src/autoscaling.rs
assert_flags \
  "orchestrator=true worker=true autoscaler=false" \
  docker/runtime-base/Dockerfile docker/common/runtime-common.sh
assert_flags \
  "orchestrator=true worker=false autoscaler=false" \
  docker/release/Dockerfile docker/orchestrator/entrypoint.sh \
  config/workflow-throughput-overlay.md
assert_flags \
  "orchestrator=false worker=true autoscaler=false" \
  docker/worker/Dockerfile config/sshd_config.d/worker.conf
assert_flags \
  "orchestrator=false worker=false autoscaler=true" \
  docker/autoscaler/Dockerfile
assert_flags \
  "orchestrator=false worker=false autoscaler=false" \
  README.md k8s/base/orchestrator-deployment.yaml \
  scripts/deploy-digitalocean.sh tests/test-doks-deploy.sh \
  config/workflow-runtime.yaml

assert_deployment_flags() {
  local expected="$1"
  local repository="$2"
  local live="$3"
  local target="$4"
  local actual
  actual="$(cd "$repository" && \
    IMAGE_INPUT_CLASSIFIER="$CLASSIFIER" \
    "$DEPLOYMENT_CLASSIFIER" "$live" "$target" |
    sed -n '1,3p' | paste -sd ' ' -)"
  if [[ "$actual" != "$expected" ]]; then
    echo "unexpected deployed-range classification" >&2
    echo "expected: $expected" >&2
    echo "actual:   $actual" >&2
    exit 1
  fi
}

range_repo="$TEMP_DIR/range-repo"
git init -q "$range_repo"
git -C "$range_repo" config user.name test
git -C "$range_repo" config user.email test@example.com
git -C "$range_repo" config commit.gpgsign false
printf 'base\n' > "$range_repo/README.md"
git -C "$range_repo" add README.md
git -C "$range_repo" commit -qm base
base_branch="$(git -C "$range_repo" branch --show-current)"
live_source="$(git -C "$range_repo" rev-parse HEAD)"

mkdir -p "$range_repo/docker/runtime-base"
printf 'FROM scratch\n' > "$range_repo/docker/runtime-base/Dockerfile"
git -C "$range_repo" add docker/runtime-base/Dockerfile
git -C "$range_repo" commit -qm runtime
failed_predecessor="$(git -C "$range_repo" rev-parse HEAD)"
mkdir -p "$range_repo/docker/autoscaler"
printf 'FROM scratch\n' > "$range_repo/docker/autoscaler/Dockerfile"
git -C "$range_repo" add docker/autoscaler/Dockerfile
git -C "$range_repo" commit -qm autoscaler
multi_commit_target="$(git -C "$range_repo" rev-parse HEAD)"

assert_deployment_flags "$all_true" "$range_repo" \
  "$live_source" "$multi_commit_target"
assert_deployment_flags \
  "orchestrator=false worker=false autoscaler=true" \
  "$range_repo" "$failed_predecessor" "$multi_commit_target"
# If the failed predecessor never deployed, the authoritative older source
# still includes both commits in the next classification.
assert_deployment_flags "$all_true" "$range_repo" \
  "$live_source" "$multi_commit_target"

git -C "$range_repo" checkout -qb divergent "$live_source"
mkdir -p "$range_repo/docker"
printf 'FROM scratch\n' > "$range_repo/docker/release.Dockerfile"
git -C "$range_repo" add docker/release.Dockerfile
git -C "$range_repo" commit -qm divergent
divergent_source="$(git -C "$range_repo" rev-parse HEAD)"
git -C "$range_repo" checkout -q "$base_branch"
assert_deployment_flags "$all_true" "$range_repo" \
  "$divergent_source" "$multi_commit_target"
assert_deployment_flags "$all_true" "$range_repo" \
  "" "$multi_commit_target"
assert_deployment_flags "$all_true" "$range_repo" \
  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$multi_commit_target"

mock_bin="$TEMP_DIR/bin"
mkdir -p "$mock_bin"
cat > "$mock_bin/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "${DOCKER_INSPECT_FAIL:-false}" == "true" ]]; then
  exit 1
fi
printf '%s\n' "${DOCKER_RESOLVED_DIGEST:-sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
EOF
chmod +x "$mock_bin/docker"
test_image="ghcr.io/jasonmorganson/symphony-k8s-orchestrator@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
DOCKER="$mock_bin/docker" "$VERIFY_DIGEST" orchestrator "$test_image" \
  ghcr.io/jasonmorganson/symphony-k8s-orchestrator >/dev/null
if DOCKER="$mock_bin/docker" \
    DOCKER_RESOLVED_DIGEST="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
    "$VERIFY_DIGEST" orchestrator "$test_image" \
    ghcr.io/jasonmorganson/symphony-k8s-orchestrator; then
  echo "mismatched registry digest must fail verification" >&2
  exit 1
fi
if DOCKER="$mock_bin/docker" DOCKER_INSPECT_FAIL=true \
    "$VERIFY_DIGEST" orchestrator "$test_image" \
    ghcr.io/jasonmorganson/symphony-k8s-orchestrator; then
  echo "deleted or unresolvable registry digest must fail verification" >&2
  exit 1
fi

grep -F 'name: Read exact live deployment state' "$WORKFLOW" >/dev/null
grep -F 'automatic bootstrap requires operator-provided runtime inputs' \
  "$WORKFLOW" >/dev/null
grep -F 'runtime is partial; refusing automatic deployment planning' \
  "$WORKFLOW" >/dev/null
if grep -F 'bootstrap: ${{ steps.live.outputs.bootstrap }}' \
    "$WORKFLOW"; then
  echo "automatic workflow must not advertise an unwired bootstrap mode" >&2
  exit 1
fi
grep -F 'incomplete live state requires rebuilding every image' \
  "$WORKFLOW" >/dev/null
grep -F 'scripts/classify-deployment-images.sh' "$WORKFLOW" >/dev/null
grep -F 'REUSE_AVAILABLE: ${{ needs.deployment-plan.outputs.reuse_available }}' \
  "$WORKFLOW" >/dev/null
grep -F 'LIVE_SOURCE_REVISION: ${{ needs.deployment-plan.outputs.source_revision }}' \
  "$WORKFLOW" >/dev/null
if grep -F 'elif [[ "${{ needs.deployment-plan.outputs.reuse_available }}" ==' \
    "$WORKFLOW"; then
  echo "classify must not interpolate an empty skipped-job output into a shell conditional" >&2
  exit 1
fi
if grep -F 'if [[ "${{ needs.deployment-plan.outputs.reuse_available }}" !=' \
    "$WORKFLOW"; then
  echo "publish must not interpolate a job output into a split shell comparison" >&2
  exit 1
fi
grep -F 'if [[ "$REUSE_AVAILABLE" != "true" ]] &&' "$WORKFLOW" >/dev/null
grep -F "if: always() && needs.classify.result == 'success'" \
  "$WORKFLOW" >/dev/null
grep -F 'scripts/verify-image-digest.sh' "$WORKFLOW" >/dev/null
grep -F 'orchestrator_image=$orchestrator_image' "$WORKFLOW" >/dev/null
grep -F 'worker_image=$worker_image' "$WORKFLOW" >/dev/null
grep -F 'autoscaler_image=$autoscaler_image' "$WORKFLOW" >/dev/null
grep -F 'SYMPHONY_REUSE_ORCHESTRATOR_IMAGE:' "$WORKFLOW" >/dev/null
grep -F 'SYMPHONY_SKIP_UNCHANGED_WORKER_RESTART:' "$WORKFLOW" >/dev/null
grep -F 'SYMPHONY_REUSE_AUTOSCALER_IMAGE:' "$WORKFLOW" >/dev/null

echo "image input classifier tests passed"
