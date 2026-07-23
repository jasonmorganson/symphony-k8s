#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUSTOMIZE="${KUSTOMIZE:-kubectl kustomize}"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

cp -R "$ROOT_DIR/k8s" "$TEMP_DIR/k8s"
generated="$TEMP_DIR/k8s/base/generated/skaffold"
mkdir -p "$generated/workflow" "$generated/secrets" "$generated/ssh"

printf '%s\n' '---' 'tracker:' '  kind: linear' '---' 'test workflow' \
  > "$generated/workflow/WORKFLOW.md"
printf '%s\n' \
  'LINEAR_API_KEY=test-linear' \
  'OPENAI_API_KEY=test-openai' \
  'SYMPHONY_WORKER_DRAIN_TOKEN=test-drain' \
  > "$generated/secrets/symphony-secrets.env"
printf '%s\n' 'test-private-key' > "$generated/ssh/orchestrator_id_ed25519"
printf '%s\n' 'ssh-ed25519 test-public-key' > "$generated/ssh/orchestrator_id_ed25519.pub"
printf '%s\n' 'worker.example ssh-ed25519 test-host-key' > "$generated/ssh/known_hosts"
printf '%s\n' 'Host worker.example' > "$generated/ssh/config"
printf '%s\n' 'test-host-private-key' > "$generated/ssh/ssh_host_ed25519_key"
printf '%s\n' 'ssh-ed25519 test-host-public-key' > "$generated/ssh/ssh_host_ed25519_key.pub"

read -r -a kustomize_command <<< "$KUSTOMIZE"
"${kustomize_command[@]}" "$TEMP_DIR/k8s/digitalocean" > "$TEMP_DIR/cd.yaml"
"${kustomize_command[@]}" "$TEMP_DIR/k8s" > "$TEMP_DIR/bootstrap.yaml"

if grep -Eq '^kind:[[:space:]]+Secret[[:space:]]*$' "$TEMP_DIR/cd.yaml"; then
  echo "CD overlay must not render Secrets" >&2
  exit 1
fi
if grep -A2 -E '^kind:[[:space:]]+ConfigMap[[:space:]]*$' "$TEMP_DIR/cd.yaml" |
    grep -Fq 'name: symphony-workflow'; then
  echo "CD overlay must not render the runtime workflow ConfigMap" >&2
  exit 1
fi

[[ "$(grep -Ec '^kind:[[:space:]]+Secret[[:space:]]*$' "$TEMP_DIR/bootstrap.yaml")" == "4" ]]
grep -A4 -E '^kind:[[:space:]]+ConfigMap[[:space:]]*$' "$TEMP_DIR/bootstrap.yaml" |
  grep -Fq 'name: symphony-workflow'
for name in \
  symphony-secrets \
  symphony-orchestrator-ssh \
  symphony-worker-authorized-keys \
  symphony-worker-hostkeys; do
  grep -Fq "name: $name" "$TEMP_DIR/bootstrap.yaml"
  if grep -Eq "name: ${name}-[a-z0-9]{6,}" "$TEMP_DIR/bootstrap.yaml"; then
    echo "bootstrap resource name must remain stable: $name" >&2
    exit 1
  fi
done

grep -A3 -F 'secretRef:' "$TEMP_DIR/bootstrap.yaml" | grep -Fq 'name: symphony-secrets'
grep -Fq 'secretName: symphony-orchestrator-ssh' "$TEMP_DIR/bootstrap.yaml"
grep -Fq 'secretName: symphony-worker-authorized-keys' "$TEMP_DIR/bootstrap.yaml"
grep -Fq 'secretName: symphony-worker-hostkeys' "$TEMP_DIR/bootstrap.yaml"
grep -Fq 'name: symphony-workflow' "$TEMP_DIR/bootstrap.yaml"

echo "Kustomize boundary tests passed"
