#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

required=(LINEAR_API_KEY OPENAI_API_KEY SYMPHONY_WORKER_DRAIN_TOKEN)
missing=()
for name in "${required[@]}"; do
  if [[ -z "${!name:-}" ]]; then
    missing+=("$name")
  fi
done

if (( ${#missing[@]} > 0 )); then
  printf 'Missing required environment variables: %s\n' "${missing[*]}" >&2
  exit 1
fi

root="$ROOT_DIR/k8s/base/generated/skaffold"
workflow_dir="$root/workflow"
secrets_dir="$root/secrets"
ssh_dir="$root/ssh"
mkdir -p "$workflow_dir" "$secrets_dir" "$ssh_dir"

write_if_changed() {
  local target="$1"
  local content="$2"
  local tmp
  tmp="$(mktemp)"
  printf '%s\n' "$content" > "$tmp"
  if [[ -f "$target" ]] && cmp -s "$tmp" "$target"; then
    rm -f "$tmp"
    return 0
  fi
  mv "$tmp" "$target"
}

workflow_file="${SYMPHONY_WORKFLOW_FILE:-$ROOT_DIR/../arrusted-development/WORKFLOW.md}"
runtime_file="$ROOT_DIR/config/workflow-runtime.yaml"
if [[ ! -f "$workflow_file" ]]; then
  printf 'Missing canonical workflow: %s\n' "$workflow_file" >&2
  printf 'Set SYMPHONY_WORKFLOW_FILE to the checked-out arrusted-development/WORKFLOW.md.\n' >&2
  exit 1
fi
if [[ ! -f "$runtime_file" ]]; then
  printf 'Missing Kubernetes workflow runtime configuration: %s\n' "$runtime_file" >&2
  exit 1
fi
workflow_repository="$(git -C "$(dirname "$workflow_file")" rev-parse --show-toplevel)"
policy_file="$workflow_repository/.config/symphony/requester-policy.json"
if [[ ! -f "$policy_file" ]]; then
  printf 'Missing canonical requester policy: %s\n' "$policy_file" >&2
  exit 1
fi
if [[ "${SYMPHONY_REQUIRE_CLEAN_MAIN_SOURCE:-0}" == "1" ]]; then
  if [[ "$(git -C "$workflow_repository" branch --show-current)" != "main" ]]; then
    printf 'Canonical workflow source must be checked out on main: %s\n' "$workflow_repository" >&2
    exit 1
  fi
  if [[ -n "$(git -C "$workflow_repository" status --porcelain=v1)" ]]; then
    printf 'Canonical workflow source must be clean: %s\n' "$workflow_repository" >&2
    exit 1
  fi
  git -C "$workflow_repository" fetch origin main --quiet
  if [[ "$(git -C "$workflow_repository" rev-parse HEAD)" != \
        "$(git -C "$workflow_repository" rev-parse origin/main)" ]]; then
    printf 'Canonical workflow source is stale relative to origin/main: %s\n' \
      "$workflow_repository" >&2
    exit 1
  fi
fi
workflow_revision="$(git -C "$workflow_repository" rev-parse HEAD)"
if grep -Fq 'Human Review' "$workflow_file" || ! grep -Fq 'In Review' "$workflow_file"; then
  printf 'Canonical workflow must contain In Review and no Human Review: %s\n' "$workflow_file" >&2
  exit 1
fi

orchestrator_key="$ssh_dir/orchestrator_id_ed25519"
worker_host_key="$ssh_dir/ssh_host_ed25519_key"

if [[ ! -f "$orchestrator_key" ]]; then
  ssh-keygen -t ed25519 -N "" -f "$orchestrator_key" -C "symphony-orchestrator" >/dev/null
fi

if [[ ! -f "$worker_host_key" ]]; then
  ssh-keygen -t ed25519 -N "" -f "$worker_host_key" -C "symphony-worker-host" >/dev/null
fi

read -r host_key_type host_key_body _ < "$worker_host_key.pub"
if [[ -z "${host_key_type:-}" || -z "${host_key_body:-}" ]]; then
  printf 'Invalid worker host public key material\n' >&2
  exit 1
fi

write_if_changed "$ssh_dir/known_hosts" "$(cat <<EOF
symphony-worker-0.symphony-worker.symphony.svc.cluster.local $host_key_type $host_key_body
symphony-worker-1.symphony-worker.symphony.svc.cluster.local $host_key_type $host_key_body
symphony-worker-2.symphony-worker.symphony.svc.cluster.local $host_key_type $host_key_body
symphony-worker-3.symphony-worker.symphony.svc.cluster.local $host_key_type $host_key_body
symphony-worker-4.symphony-worker.symphony.svc.cluster.local $host_key_type $host_key_body
EOF
)"

write_if_changed "$ssh_dir/config" "$(cat <<'EOF'
Host symphony-worker-*.symphony-worker.symphony.svc.cluster.local
  User symphony
  IdentityFile /home/symphony/.ssh/id_ed25519
  StrictHostKeyChecking yes
  UserKnownHostsFile /home/symphony/.ssh/known_hosts
EOF
)"

write_if_changed "$secrets_dir/symphony-secrets.env" "$(cat <<EOF
LINEAR_API_KEY=${LINEAR_API_KEY}
OPENAI_API_KEY=${OPENAI_API_KEY}
SYMPHONY_WORKER_DRAIN_TOKEN=${SYMPHONY_WORKER_DRAIN_TOKEN}
${GITHUB_TOKEN:+GITHUB_TOKEN=${GITHUB_TOKEN}}
EOF
)"

workflow_body="$(awk 'BEGIN { separators = 0 } /^---$/ { separators++; next } separators >= 2 { print }' "$workflow_file")"
if [[ -z "$workflow_body" ]]; then
  printf 'Canonical workflow has no prompt body after YAML front matter: %s\n' "$workflow_file" >&2
  exit 1
fi

write_if_changed "$workflow_dir/WORKFLOW.md" "$(printf '%s\n%s\n%s\n%s' '---' "$(cat "$runtime_file")" '---' "$workflow_body")"
cp "$policy_file" "$workflow_dir/requester-policy.json"
write_if_changed "$workflow_dir/workflow-source.json" "$(printf \
  '{"repository":"%s","revision":"%s","workflow":"WORKFLOW.md","requester_policy":".config/symphony/requester-policy.json"}' \
  "$(git -C "$workflow_repository" config --get remote.origin.url)" "$workflow_revision")"
