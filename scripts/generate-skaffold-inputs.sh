#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

required=(LINEAR_API_KEY OPENAI_API_KEY LINEAR_PROJECT_SLUG REPO_URL)
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

template_file="$ROOT_DIR/workflow/WORKFLOW.md"
if [[ ! -f "$template_file" ]]; then
  printf 'Missing workflow template: %s\n' "$template_file" >&2
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

cat > "$ssh_dir/known_hosts" <<EOF
symphony-worker-0.symphony-worker.symphony.svc.cluster.local $host_key_type $host_key_body
symphony-worker-1.symphony-worker.symphony.svc.cluster.local $host_key_type $host_key_body
symphony-worker-2.symphony-worker.symphony.svc.cluster.local $host_key_type $host_key_body
EOF

cat > "$ssh_dir/config" <<'EOF'
Host symphony-worker-*.symphony-worker.symphony.svc.cluster.local
  User symphony
  IdentityFile /home/symphony/.ssh/id_ed25519
  StrictHostKeyChecking yes
  UserKnownHostsFile /home/symphony/.ssh/known_hosts
EOF

cat > "$secrets_dir/symphony-secrets.env" <<EOF
LINEAR_API_KEY=${LINEAR_API_KEY}
OPENAI_API_KEY=${OPENAI_API_KEY}
EOF

escape_sed_replacement() {
  printf '%s' "$1" | sed 's/[&|\\]/\\&/g'
}

rendered_workflow="$(sed \
  -e "s|__LINEAR_PROJECT_SLUG__|$(escape_sed_replacement "$LINEAR_PROJECT_SLUG")|g" \
  -e "s|__REPO_URL__|$(escape_sed_replacement "$REPO_URL")|g" \
  "$template_file")"

printf '%s\n' "$rendered_workflow" > "$workflow_dir/WORKFLOW.md"
