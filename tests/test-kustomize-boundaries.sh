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
printf '%s\n' '{"repository":"test","revision":"test"}' \
  > "$generated/workflow/workflow-source.json"
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
grep -Fq 'workflow-source.json:' "$TEMP_DIR/bootstrap.yaml"
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

orchestrator_manifest="$TEMP_DIR/orchestrator.yaml"
awk '
  /^kind: Deployment$/ { in_deployment = 1 }
  in_deployment && /^  name: symphony-orchestrator$/ { is_orchestrator = 1 }
  is_orchestrator { print }
  is_orchestrator && /^---$/ { exit }
' "$TEMP_DIR/cd.yaml" > "$orchestrator_manifest"

worker_manifest="$TEMP_DIR/worker.yaml"
awk '
  /^kind: StatefulSet$/ { in_statefulset = 1 }
  in_statefulset && /^  name: symphony-worker$/ { is_worker = 1 }
  is_worker { print }
  is_worker && /^---$/ { exit }
' "$TEMP_DIR/cd.yaml" > "$worker_manifest"

grep -A5 -F 'startupProbe:' "$orchestrator_manifest" | grep -Fq 'failureThreshold: 180'
grep -A7 -F 'readinessProbe:' "$orchestrator_manifest" | grep -Fq 'timeoutSeconds: 10'
grep -A7 -F 'readinessProbe:' "$orchestrator_manifest" | grep -Fq 'failureThreshold: 6'
grep -A8 -F 'livenessProbe:' "$orchestrator_manifest" | grep -Fq 'timeoutSeconds: 10'
grep -A8 -F 'livenessProbe:' "$orchestrator_manifest" | grep -Fq 'failureThreshold: 6'
grep -Fq 'podManagementPolicy: Parallel' "$worker_manifest"
grep -Fq 'chmod 2777 /srv/symphony/workspaces' "$worker_manifest"
grep -A9 -F 'startupProbe:' "$worker_manifest" | grep -Fq 'failureThreshold: 60'
if grep -Fq 'chown -R 10001:10001 /srv/symphony/workspaces' "$worker_manifest"; then
  echo "worker startup must not recursively chown the workspace tree" >&2
  exit 1
fi

echo "Kustomize boundary tests passed"
