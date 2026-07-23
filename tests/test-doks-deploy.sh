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

cat > "$TEMP_DIR/doctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DOCTL_LOG"
if [[ "${DOCTL_ERROR:-0}" == "1" ]]; then
  exit 1
fi
EOF
chmod +x "$TEMP_DIR/doctl"

export KUBECTL_LOG="$TEMP_DIR/kubectl.log"
export DOCTL_LOG="$TEMP_DIR/doctl.log"
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

Human Review moves to Merging after requester approval.
EOF
cat > "$SOURCE_REPO/.config/symphony/requester-policy.json" <<'EOF'
{
  "$schema": "./requester-policy.schema.json",
  "schema_version": 1,
  "repository": "withAutograph/arrusted-development",
  "machine_login": "autograph-symphony",
  "runtime_scope": ["local", "vm", "container", "kubernetes"],
  "requester": {
    "source": "linear_issue_creator",
    "resolution": "exactly_one_mapping_or_fail_closed",
    "creator_email_mappings": [
      {
        "linear_creator_email": "jason@withgraph.com",
        "github_login": "jasonmorganson"
      }
    ]
  },
  "pull_request": {
    "attached_open_count": 1,
    "author": "machine_login",
    "reconciliation": {
      "none": "create",
      "one": "reuse_and_repair",
      "ambiguous": "fail_closed"
    },
    "required_body_metadata": [
      "requester",
      "canonical_linear_issue_link",
      "exactly_one_fixes_issue_id"
    ],
    "review_request": "mapped_requester_on_create_or_reuse"
  },
  "approval_handoff": {
    "source_state": "Human Review",
    "destination_state": "Merging",
    "review_pull_request": "attached_open_pull_request",
    "actor": "mapped_requester",
    "actor_type": "human",
    "state": "APPROVED",
    "latest_by": "submitted_at",
    "ignored_review_states": ["COMMENTED"],
    "conflicting_latest_timestamp": "fail_closed",
    "concurrent_state_drift": "fail_closed"
  },
  "monitor": {
    "owner": "existing_workflow_monitor",
    "polling": "existing_monitor_loop",
    "discovery": "github_open_machine_pull_requests",
    "linear_access": "approved_candidates_only",
    "github_credential": "github-machine-arrusted-symphony"
  }
}
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
  DOCTL="$TEMP_DIR/doctl" \
  DOKS_CLUSTER=production-cluster \
  SYMPHONY_SYSTEM_NODE_POOL=durable-system \
  SYMPHONY_WORKER_NODE_POOL=worker-pool \
  bash "$ROOT_DIR/scripts/deploy-digitalocean.sh"

kubectl kustomize "$ROOT_DIR/k8s/digitalocean" > "$TEMP_DIR/rendered.yaml"
grep -q 'requester-policy.json:' "$TEMP_DIR/rendered.yaml"
grep -q 'workflow-source.json:' "$TEMP_DIR/rendered.yaml"
source_revision="$(git -C "$SOURCE_REPO" rev-parse HEAD)"
grep -q "\"revision\":\"$source_revision\"" "$TEMP_DIR/rendered.yaml"
grep -q 'Human Review' "$TEMP_DIR/rendered.yaml"
if grep -q 'In Review' "$TEMP_DIR/rendered.yaml"; then
  echo "rendered workflow ConfigMap must not contain In Review" >&2
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
grep -F "kubernetes cluster node-pool update production-cluster worker-pool --auto-scale --min-nodes 0 --max-nodes 10" "$DOCTL_LOG"
grep -F "apply -f " "$KUBECTL_LOG"
for deployment in coredns konnectivity-agent hubble-relay hubble-ui; do
  grep -F -- "-n kube-system patch deployment $deployment --type=strategic" "$KUBECTL_LOG"
  grep -F -- "-n kube-system rollout status deployment/$deployment --timeout=5m" "$KUBECTL_LOG"
done
grep -F '"doks.digitalocean.com/node-pool":"durable-system"' "$KUBECTL_LOG"
grep -F '"key":"symphony.morganson.me/workload"' "$KUBECTL_LOG"

python3 - "$SOURCE_REPO/.config/symphony/requester-policy.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as source:
    policy = json.load(source)
policy["approval_handoff"]["source_state"] = "In Review"
with open(path, "w", encoding="utf-8") as target:
    json.dump(policy, target)
PY
git -C "$SOURCE_REPO" add .config/symphony/requester-policy.json
git -C "$SOURCE_REPO" commit -m "stale requester policy" >/dev/null
git -C "$SOURCE_REPO" push origin main >/dev/null
: > "$KUBECTL_LOG"
: > "$DOCTL_LOG"
if bash "$ROOT_DIR/scripts/deploy-digitalocean.sh"; then
  echo "stale requester policy must fail preflight" >&2
  exit 1
fi
if ! cmp -s "$SOURCE_REPO/.config/symphony/requester-policy.json" \
    "$ROOT_DIR/k8s/base/generated/skaffold/workflow/requester-policy.json"; then
  echo "preflight must validate the exact copied requester policy" >&2
  exit 1
fi
if grep -F "apply -f" "$KUBECTL_LOG" || [[ -s "$DOCTL_LOG" ]]; then
  echo "stale requester policy must fail before provider mutation" >&2
  exit 1
fi
python3 - "$SOURCE_REPO/.config/symphony/requester-policy.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as source:
    policy = json.load(source)
policy["approval_handoff"]["source_state"] = "Human Review"
with open(path, "w", encoding="utf-8") as target:
    json.dump(policy, target)
PY
git -C "$SOURCE_REPO" add .config/symphony/requester-policy.json
git -C "$SOURCE_REPO" commit -m "restore requester policy" >/dev/null
git -C "$SOURCE_REPO" push origin main >/dev/null

cp "$SOURCE_REPO/.config/symphony/requester-policy.json" "$TEMP_DIR/valid-requester-policy.json"
python3 - "$SOURCE_REPO/.config/symphony/requester-policy.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as source:
    policy = json.load(source)
del policy["monitor"]
with open(path, "w", encoding="utf-8") as target:
    json.dump(policy, target)
PY
git -C "$SOURCE_REPO" add .config/symphony/requester-policy.json
git -C "$SOURCE_REPO" commit -m "malformed requester policy" >/dev/null
git -C "$SOURCE_REPO" push origin main >/dev/null
: > "$KUBECTL_LOG"
: > "$DOCTL_LOG"
if bash "$ROOT_DIR/scripts/deploy-digitalocean.sh"; then
  echo "malformed requester policy must fail preflight" >&2
  exit 1
fi
if ! cmp -s "$SOURCE_REPO/.config/symphony/requester-policy.json" \
    "$ROOT_DIR/k8s/base/generated/skaffold/workflow/requester-policy.json"; then
  echo "preflight must validate the exact copied requester policy" >&2
  exit 1
fi
if grep -F "apply -f" "$KUBECTL_LOG" || [[ -s "$DOCTL_LOG" ]]; then
  echo "malformed requester policy must fail before provider mutation" >&2
  exit 1
fi
cp "$TEMP_DIR/valid-requester-policy.json" \
  "$SOURCE_REPO/.config/symphony/requester-policy.json"
git -C "$SOURCE_REPO" add .config/symphony/requester-policy.json
git -C "$SOURCE_REPO" commit -m "restore valid requester policy" >/dev/null
git -C "$SOURCE_REPO" push origin main >/dev/null

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
: > "$DOCTL_LOG"
KUBECTL="$TEMP_DIR/kubectl" \
  DOCTL="$TEMP_DIR/doctl" \
  MISSING_DEPLOYMENTS=hubble-relay,hubble-ui \
  bash "$ROOT_DIR/scripts/deploy-digitalocean.sh"
grep -F "kubernetes cluster node-pool update symphony-k8s symphony-ha --auto-scale --min-nodes 0 --max-nodes 10" "$DOCTL_LOG"
for deployment in coredns konnectivity-agent; do
  grep -F -- "-n kube-system patch deployment $deployment --type=strategic" "$KUBECTL_LOG"
done
if grep -F -- "patch deployment hubble-" "$KUBECTL_LOG"; then
  echo "disabled optional Hubble deployments must not be patched" >&2
  exit 1
fi

: > "$KUBECTL_LOG"
: > "$DOCTL_LOG"
if KUBECTL="$TEMP_DIR/kubectl" MISSING_DEPLOYMENTS=coredns \
    DOCTL="$TEMP_DIR/doctl" \
    bash "$ROOT_DIR/scripts/deploy-digitalocean.sh"; then
  echo "missing required deployment must fail preflight" >&2
  exit 1
fi
if grep -F "apply -f" "$KUBECTL_LOG"; then
  echo "overlay must not be applied after failed preflight" >&2
  exit 1
fi
if [[ -s "$DOCTL_LOG" ]]; then
  echo "node pool must not be changed after failed preflight" >&2
  exit 1
fi

: > "$KUBECTL_LOG"
: > "$DOCTL_LOG"
if KUBECTL="$TEMP_DIR/kubectl" API_ERROR_DEPLOYMENTS=hubble-relay \
    DOCTL="$TEMP_DIR/doctl" \
    bash "$ROOT_DIR/scripts/deploy-digitalocean.sh"; then
  echo "optional deployment API errors must fail preflight" >&2
  exit 1
fi
if grep -F "apply -f" "$KUBECTL_LOG"; then
  echo "overlay must not be applied after an optional deployment API error" >&2
  exit 1
fi
if [[ -s "$DOCTL_LOG" ]]; then
  echo "node pool must not be changed after an optional deployment API error" >&2
  exit 1
fi

: > "$KUBECTL_LOG"
: > "$DOCTL_LOG"
if KUBECTL="$TEMP_DIR/kubectl" DOCTL="$TEMP_DIR/doctl" DOCTL_ERROR=1 \
    bash "$ROOT_DIR/scripts/deploy-digitalocean.sh"; then
  echo "node-pool reconciliation errors must fail deployment" >&2
  exit 1
fi
if grep -F "apply -k" "$KUBECTL_LOG"; then
  echo "overlay must not be applied after failed node-pool reconciliation" >&2
  exit 1
fi

: > "$KUBECTL_LOG"
: > "$DOCTL_LOG"
if KUBECTL="$TEMP_DIR/kubectl" DOCTL="$TEMP_DIR/doctl" \
    SYMPHONY_WORKER_MIN_NODES=11 SYMPHONY_WORKER_MAX_NODES=10 \
    bash "$ROOT_DIR/scripts/deploy-digitalocean.sh"; then
  echo "invalid node-pool bounds must fail deployment" >&2
  exit 1
fi
if [[ -s "$KUBECTL_LOG" || -s "$DOCTL_LOG" ]]; then
  echo "invalid node-pool bounds must fail before provider or cluster access" >&2
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
git clone --branch main "$SOURCE_REMOTE" "$ADVANCE_REPO" >/dev/null
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
