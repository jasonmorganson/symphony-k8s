#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUSTOMIZE="${KUSTOMIZE:-kubectl kustomize}"
output="$(mktemp)"
trap 'rm -f "$output"' EXIT
read -r -a command <<< "$KUSTOMIZE"
"${command[@]}" "$ROOT_DIR/k8s/digitalocean" > "$output"

grep -q 'kind: StatefulSet' "$output"
grep -A7 -F 'startupProbe:' "$output" | grep -Fq 'timeoutSeconds: 10'
grep -A8 -F 'readinessProbe:' "$output" | grep -Fq 'timeoutSeconds: 10'
grep -A8 -F 'readinessProbe:' "$output" | grep -Fq 'failureThreshold: 6'
grep -A8 -F 'startupProbe:' "$output" | grep -Fq 'path: /healthz'
grep -A8 -F 'readinessProbe:' "$output" | grep -Fq 'path: /healthz'
grep -A8 -F 'livenessProbe:' "$output" | grep -Fq 'path: /healthz'
grep -A8 -F 'livenessProbe:' "$output" | grep -Fq 'port: http'
grep -A10 -F 'livenessProbe:' "$output" | grep -Fq 'failureThreshold: 6'
grep -q 'name: symphony-worker' "$output"
grep -q 'type: Recreate' "$output"
grep -q 'progressDeadlineSeconds: 2100' "$output"
grep -q 'failureThreshold: 360' "$output"
if grep -Eq 'symphony-autoscaler|workspace-reclaimer|volumeClaimTemplates|workflow-throughput-overlay' "$output"; then
  echo "removed controller or durable workspace leaked into Kustomize output" >&2
  exit 1
fi
if grep -Eq '^kind: Secret$' "$output"; then
  echo "Kustomize must reference, not render, production secrets" >&2
  exit 1
fi

echo "Kustomize infrastructure boundaries are valid"
