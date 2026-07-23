#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

ROOT_DIR="$TEMP_DIR/symphony-k8s"
mkdir -p "$ROOT_DIR"
(
  cd "$SOURCE_ROOT"
  tar --exclude=.git --exclude=k8s/base/generated -cf - .
) | (
  cd "$ROOT_DIR"
  tar -xf -
)
git init -b master "$ROOT_DIR" >/dev/null
git -C "$ROOT_DIR" config user.name "Test"
git -C "$ROOT_DIR" config user.email "test@example.com"
git -C "$ROOT_DIR" config commit.gpgsign false
git -C "$ROOT_DIR" add .
git -C "$ROOT_DIR" commit -m "test symphony deployment" >/dev/null
SYMPHONY_REMOTE="$TEMP_DIR/symphony.git"
git init --bare "$SYMPHONY_REMOTE" >/dev/null
git -C "$ROOT_DIR" remote add origin "$SYMPHONY_REMOTE"
git -C "$ROOT_DIR" push -u origin master >/dev/null

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
cat > "$TEMP_DIR/docker" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" != *"symphony-k8s-autoscaler:${EXPECTED_SYMPHONY_REVISION}"* ]]; then
  echo "missing revision tag" >&2
  exit 1
fi
printf '"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"\n'
EOF
chmod +x "$TEMP_DIR/docker"

export KUBECTL_LOG="$TEMP_DIR/kubectl.log"
SOURCE_REMOTE="$TEMP_DIR/arrusted.git"
SOURCE_REPO="$TEMP_DIR/arrusted-development"
git init --bare "$SOURCE_REMOTE" >/dev/null
git init -b main "$SOURCE_REPO" >/dev/null
git -C "$SOURCE_REPO" config user.name "Test"
git -C "$SOURCE_REPO" config user.email "test@example.com"
git -C "$SOURCE_REPO" config commit.gpgsign false
mkdir -p "$SOURCE_REPO/.config/symphony"
cat > "$SOURCE_REPO/WORKFLOW.md" <<'EOF'
---
tracker:
  active_states:
    - Todo
---
# Test workflow

In Review moves to Merging after requester approval.
EOF
cat > "$SOURCE_REPO/.config/symphony/requester-policy.json" <<'EOF'
{"schema_version":1,"approval_handoff":{"source_state":"In Review","destination_state":"Merging"}}
EOF
git -C "$SOURCE_REPO" add WORKFLOW.md .config/symphony/requester-policy.json
git -C "$SOURCE_REPO" commit -m "test workflow" >/dev/null
git -C "$SOURCE_REPO" remote add origin "$SOURCE_REMOTE"
git -C "$SOURCE_REPO" push -u origin main >/dev/null

export LINEAR_API_KEY=test-linear
export OPENAI_API_KEY=test-openai
export SYMPHONY_WORKER_DRAIN_TOKEN=01234567890123456789012345678901
export SYMPHONY_WORKFLOW_FILE="$SOURCE_REPO/WORKFLOW.md"
export SYMPHONY_IMAGE_INSPECTOR="$TEMP_DIR/docker"
export EXPECTED_SYMPHONY_REVISION="$(git -C "$ROOT_DIR" rev-parse HEAD)"
export KUSTOMIZE=kubectl

KUBECTL="$TEMP_DIR/kubectl" \
  SYMPHONY_SYSTEM_NODE_POOL=durable-system \
  bash "$ROOT_DIR/scripts/deploy-digitalocean.sh"

kubectl kustomize "$ROOT_DIR/k8s/digitalocean" > "$TEMP_DIR/rendered.yaml"
grep -q 'requester-policy.json:' "$TEMP_DIR/rendered.yaml"
grep -q 'workflow-source.json:' "$TEMP_DIR/rendered.yaml"
source_revision="$(git -C "$SOURCE_REPO" rev-parse HEAD)"
grep -q "\"revision\":\"$source_revision\"" "$TEMP_DIR/rendered.yaml"
grep -q 'In Review' "$TEMP_DIR/rendered.yaml"
if grep -q 'Human Review' "$TEMP_DIR/rendered.yaml"; then
  echo "rendered workflow ConfigMap must not contain Human Review" >&2
  exit 1
fi
workflow_config_name="$(
  sed -n 's/^  name: \(symphony-workflow-[a-z0-9]*\)$/\1/p' "$TEMP_DIR/rendered.yaml" | head -1
)"
if [[ -z "$workflow_config_name" ]] || \
    [[ "$(grep -c "name: $workflow_config_name" "$TEMP_DIR/rendered.yaml")" -lt 3 ]]; then
  echo "content-addressed workflow ConfigMap must roll and mount in both deployments" >&2
  exit 1
fi
grep -A5 'name: GITHUB_TOKEN' "$TEMP_DIR/rendered.yaml" | \
  grep -q 'name: github-machine-arrusted-symphony'
grep -F "apply -f " "$KUBECTL_LOG"
for deployment in coredns konnectivity-agent hubble-relay hubble-ui; do
  grep -F -- "-n kube-system patch deployment $deployment --type=strategic" "$KUBECTL_LOG"
  grep -F -- "-n kube-system rollout status deployment/$deployment --timeout=5m" "$KUBECTL_LOG"
done
grep -F '"doks.digitalocean.com/node-pool":"durable-system"' "$KUBECTL_LOG"
grep -F '"key":"symphony.morganson.me/workload"' "$KUBECTL_LOG"

cat > "$TEMP_DIR/bad-docker" <<'EOF'
#!/usr/bin/env bash
printf '"not-a-digest"\n'
EOF
chmod +x "$TEMP_DIR/bad-docker"
: > "$KUBECTL_LOG"
if SYMPHONY_IMAGE_INSPECTOR="$TEMP_DIR/bad-docker" \
    bash "$ROOT_DIR/scripts/deploy-digitalocean.sh"; then
  echo "missing merged-revision image digest must fail preflight" >&2
  exit 1
fi
if grep -F "apply -f" "$KUBECTL_LOG"; then
  echo "invalid autoscaler image must fail before apply" >&2
  exit 1
fi

printf '\nDirty\n' >> "$ROOT_DIR/README.md"
: > "$KUBECTL_LOG"
if bash "$ROOT_DIR/scripts/deploy-digitalocean.sh"; then
  echo "dirty symphony-k8s source must fail preflight" >&2
  exit 1
fi
if grep -F "apply -f" "$KUBECTL_LOG"; then
  echo "dirty symphony-k8s source must fail before apply" >&2
  exit 1
fi
git -C "$ROOT_DIR" restore README.md

git -C "$ROOT_DIR" switch -c feature >/dev/null
: > "$KUBECTL_LOG"
if bash "$ROOT_DIR/scripts/deploy-digitalocean.sh"; then
  echo "non-master symphony-k8s source must fail preflight" >&2
  exit 1
fi
if grep -F "apply -f" "$KUBECTL_LOG"; then
  echo "non-master symphony-k8s source must fail before apply" >&2
  exit 1
fi
git -C "$ROOT_DIR" switch master >/dev/null

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
if grep -F "apply -f" "$KUBECTL_LOG"; then
  echo "overlay must not be applied after failed preflight" >&2
  exit 1
fi

: > "$KUBECTL_LOG"
if KUBECTL="$TEMP_DIR/kubectl" API_ERROR_DEPLOYMENTS=hubble-relay \
    bash "$ROOT_DIR/scripts/deploy-digitalocean.sh"; then
  echo "optional deployment API errors must fail preflight" >&2
  exit 1
fi
if grep -F "apply -f" "$KUBECTL_LOG"; then
  echo "overlay must not be applied after an optional deployment API error" >&2
  exit 1
fi

printf '\nDirty\n' >> "$SOURCE_REPO/WORKFLOW.md"
if SYMPHONY_REQUIRE_CLEAN_MAIN_SOURCE=1 \
    bash "$ROOT_DIR/scripts/generate-skaffold-inputs.sh"; then
  echo "dirty workflow source must fail preflight" >&2
  exit 1
fi
git -C "$SOURCE_REPO" restore WORKFLOW.md

git -C "$SOURCE_REPO" switch -c feature >/dev/null
if SYMPHONY_REQUIRE_CLEAN_MAIN_SOURCE=1 \
    bash "$ROOT_DIR/scripts/generate-skaffold-inputs.sh"; then
  echo "non-main workflow source must fail preflight" >&2
  exit 1
fi
git -C "$SOURCE_REPO" switch main >/dev/null

ADVANCE_REPO="$TEMP_DIR/advance"
git clone "$SOURCE_REMOTE" "$ADVANCE_REPO" >/dev/null
git -C "$ADVANCE_REPO" config user.name "Test"
git -C "$ADVANCE_REPO" config user.email "test@example.com"
git -C "$ADVANCE_REPO" config commit.gpgsign false
printf '\nRemote change\n' >> "$ADVANCE_REPO/WORKFLOW.md"
git -C "$ADVANCE_REPO" add WORKFLOW.md
git -C "$ADVANCE_REPO" commit -m "advance workflow" >/dev/null
git -C "$ADVANCE_REPO" push origin main >/dev/null
if SYMPHONY_REQUIRE_CLEAN_MAIN_SOURCE=1 \
    bash "$ROOT_DIR/scripts/generate-skaffold-inputs.sh"; then
  echo "stale workflow source must fail preflight" >&2
  exit 1
fi

SYMPHONY_ADVANCE="$TEMP_DIR/symphony-advance"
git clone --branch master "$SYMPHONY_REMOTE" "$SYMPHONY_ADVANCE" >/dev/null
git -C "$SYMPHONY_ADVANCE" config user.name "Test"
git -C "$SYMPHONY_ADVANCE" config user.email "test@example.com"
git -C "$SYMPHONY_ADVANCE" config commit.gpgsign false
printf '\nRemote change\n' >> "$SYMPHONY_ADVANCE/README.md"
git -C "$SYMPHONY_ADVANCE" add README.md
git -C "$SYMPHONY_ADVANCE" commit -m "advance deployment" >/dev/null
git -C "$SYMPHONY_ADVANCE" push origin master >/dev/null
: > "$KUBECTL_LOG"
if bash "$ROOT_DIR/scripts/deploy-digitalocean.sh"; then
  echo "stale symphony-k8s source must fail preflight" >&2
  exit 1
fi
if grep -F "apply -f" "$KUBECTL_LOG"; then
  echo "stale symphony-k8s source must fail before apply" >&2
  exit 1
fi
