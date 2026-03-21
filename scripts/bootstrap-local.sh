#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="symphony"
PROFILE="dev"
RUN_SKAFFOLD="true"

LINEAR_API_KEY="${LINEAR_API_KEY:-}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
LINEAR_PROJECT_SLUG="${LINEAR_PROJECT_SLUG:-}"
REPO_URL="${REPO_URL:-}"

usage() {
  cat <<USAGE
Usage: scripts/bootstrap-local.sh [options]

Options:
  --linear-api-key <key>       Linear API key (or env LINEAR_API_KEY)
  --openai-api-key <key>       OpenAI API key (or env OPENAI_API_KEY)
  --linear-project-slug <slug> Linear project slug for tracker config (or env LINEAR_PROJECT_SLUG)
  --repo-url <url>             Repo URL cloned in hooks.after_create (or env REPO_URL)
  --profile <name>             Skaffold profile (default: dev)
  --namespace <name>           Kubernetes namespace (default: symphony)
  --skip-skaffold              Skip skaffold run step
  -h, --help                   Show this help

Example:
  LINEAR_API_KEY=lin_xxx OPENAI_API_KEY=sk-xxx \\
  LINEAR_PROJECT_SLUG=my-project REPO_URL=https://github.com/acme/repo.git \\
  scripts/bootstrap-local.sh
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --linear-api-key)
      LINEAR_API_KEY="$2"
      shift 2
      ;;
    --openai-api-key)
      OPENAI_API_KEY="$2"
      shift 2
      ;;
    --linear-project-slug)
      LINEAR_PROJECT_SLUG="$2"
      shift 2
      ;;
    --repo-url)
      REPO_URL="$2"
      shift 2
      ;;
    --profile)
      PROFILE="$2"
      shift 2
      ;;
    --namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    --skip-skaffold)
      RUN_SKAFFOLD="false"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

for cmd in kubectl skaffold ssh-keygen; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Required command not found: $cmd" >&2
    exit 1
  fi
done

if ! kubectl config current-context >/dev/null 2>&1; then
  if [[ -f "$HOME/.kube/config" ]] && KUBECONFIG="$HOME/.kube/config" kubectl config current-context >/dev/null 2>&1; then
    export KUBECONFIG="$HOME/.kube/config"
  else
    echo "kubectl current-context is not set. Configure your cluster context first." >&2
    exit 1
  fi
fi

if [[ -z "$LINEAR_API_KEY" || -z "$OPENAI_API_KEY" || -z "$LINEAR_PROJECT_SLUG" || -z "$REPO_URL" ]]; then
  cat <<ERR >&2
Missing required config. Provide all of:
  LINEAR_API_KEY
  OPENAI_API_KEY
  LINEAR_PROJECT_SLUG
  REPO_URL
ERR
  exit 1
fi

KEY_DIR="$ROOT_DIR/generated/ssh"
mkdir -p "$KEY_DIR"

ORCH_KEY="$KEY_DIR/orchestrator_id_ed25519"
WORKER_HOST_KEY="$KEY_DIR/ssh_host_ed25519_key"

if [[ ! -f "$ORCH_KEY" ]]; then
  ssh-keygen -t ed25519 -N "" -f "$ORCH_KEY" -C "symphony-orchestrator" >/dev/null
fi

if [[ ! -f "$WORKER_HOST_KEY" ]]; then
  ssh-keygen -t ed25519 -N "" -f "$WORKER_HOST_KEY" -C "symphony-worker-host" >/dev/null
fi

WORKER_HOST_PUB_PAIR="$(awk '{print $1 " " $2}' "$WORKER_HOST_KEY.pub")"
KNOWN_HOSTS_FILE="$KEY_DIR/known_hosts"
cat > "$KNOWN_HOSTS_FILE" <<KH
symphony-worker-0.symphony-worker.${NAMESPACE}.svc.cluster.local ${WORKER_HOST_PUB_PAIR}
symphony-worker-1.symphony-worker.${NAMESPACE}.svc.cluster.local ${WORKER_HOST_PUB_PAIR}
symphony-worker-2.symphony-worker.${NAMESPACE}.svc.cluster.local ${WORKER_HOST_PUB_PAIR}
KH

SSH_CONFIG_FILE="$KEY_DIR/config"
cat > "$SSH_CONFIG_FILE" <<CFG
Host symphony-worker-*.symphony-worker.${NAMESPACE}.svc.cluster.local
  User symphony
  IdentityFile /home/symphony/.ssh/id_ed25519
  StrictHostKeyChecking yes
  UserKnownHostsFile /home/symphony/.ssh/known_hosts
CFG

WORKFLOW_FILE="$KEY_DIR/WORKFLOW.md"
cat > "$WORKFLOW_FILE" <<WF
---
tracker:
  kind: linear
  project_slug: ${LINEAR_PROJECT_SLUG}
  api_key: \$LINEAR_API_KEY

workspace:
  root: /srv/symphony/workspaces

worker:
  ssh_hosts:
    - symphony-worker-0.symphony-worker.${NAMESPACE}.svc.cluster.local
    - symphony-worker-1.symphony-worker.${NAMESPACE}.svc.cluster.local
    - symphony-worker-2.symphony-worker.${NAMESPACE}.svc.cluster.local
  max_concurrent_agents_per_host: 2

agent:
  max_concurrent_agents: 6
  max_turns: 20

codex:
  command: /usr/local/bin/codex app-server

hooks:
  after_create: |
    set -euo pipefail
    git clone ${REPO_URL} repo
    cd repo
    if [ -f package-lock.json ]; then
      npm ci
    elif [ -f pnpm-lock.yaml ]; then
      corepack enable && pnpm install --frozen-lockfile
    elif [ -f yarn.lock ]; then
      corepack enable && yarn install --frozen-lockfile
    fi
---
WF

kubectl apply -f "$ROOT_DIR/k8s/base/namespace.yaml"

kubectl -n "$NAMESPACE" create secret generic symphony-secrets \
  --from-literal=LINEAR_API_KEY="$LINEAR_API_KEY" \
  --from-literal=OPENAI_API_KEY="$OPENAI_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NAMESPACE" create secret generic symphony-orchestrator-ssh \
  --from-file=id_ed25519="$ORCH_KEY" \
  --from-file=known_hosts="$KNOWN_HOSTS_FILE" \
  --from-file=config="$SSH_CONFIG_FILE" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NAMESPACE" create secret generic symphony-worker-authorized-keys \
  --from-file=authorized_keys="$ORCH_KEY.pub" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NAMESPACE" create secret generic symphony-worker-hostkeys \
  --from-file=ssh_host_ed25519_key="$WORKER_HOST_KEY" \
  --from-file=ssh_host_ed25519_key.pub="$WORKER_HOST_KEY.pub" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$NAMESPACE" create configmap symphony-workflow \
  --from-file=WORKFLOW.md="$WORKFLOW_FILE" \
  --dry-run=client -o yaml | kubectl apply -f -

if [[ "$RUN_SKAFFOLD" == "true" ]]; then
  (cd "$ROOT_DIR" && skaffold run -p "$PROFILE" --tail=false)
fi

ORCH_POD="$(kubectl -n "$NAMESPACE" get pods -l app=symphony-orchestrator -o jsonpath='{.items[0].metadata.name}')"
kubectl -n "$NAMESPACE" exec "$ORCH_POD" -- sh -lc \
  'ssh -F /home/symphony/.ssh/config symphony-worker-0.symphony-worker.'"$NAMESPACE"'.svc.cluster.local "echo ssh-ok"'

echo
echo "Bootstrap complete."
echo "Namespace: $NAMESPACE"
echo "Skaffold profile: $PROFILE"
echo "Generated key material: $KEY_DIR"
