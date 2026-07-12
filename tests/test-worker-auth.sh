#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../docker/worker/entrypoint.sh
source "$ROOT_DIR/docker/worker/entrypoint.sh"

assert_auth_result() {
  local status="$1" expected="$2" output rc=0
  runuser() {
    if [[ "$*" != *"codex login status"* ]]; then
      echo "unexpected command: $*" >&2
      return 99
    fi
    printf '%s\n' "$status"
  }
  output="$(verify_codex_chatgpt_auth 2>&1)" || rc=$?
  if [[ "$expected" == success ]]; then
    [[ "$rc" -eq 0 && -z "$output" ]]
  else
    [[ "$rc" -ne 0 ]]
    [[ "$output" == *"API-key fallback is disabled"* ]]
  fi
}

assert_auth_result "Logged in using ChatGPT" success
assert_auth_result "Not logged in" failure
OPENAI_API_KEY=sk-test assert_auth_result "Logged in using an API key - sk-***" failure

if grep -Eq 'codex login --with-api-key|trim_secret OPENAI_API_KEY' \
  "$ROOT_DIR/docker/worker/entrypoint.sh"; then
  echo "worker entrypoint contains an API-key fallback" >&2
  exit 1
fi

worker_manifests=(
  "$ROOT_DIR/k8s/base/worker-statefulset.yaml"
  "$ROOT_DIR/k8s/digitalocean/worker-pool-patch.yaml"
  "$ROOT_DIR/k8s/digitalocean/single-node-worker-patch.yaml"
)
if grep -Eq 'OPENAI_API_KEY|envFrom:' "${worker_manifests[@]}"; then
  echo "worker manifest exposes API-key environment configuration" >&2
  exit 1
fi
grep -q 'secretName: codex-chatgpt-auth' "${worker_manifests[0]}"
grep -q 'mountPath: /home/symphony/.codex' "${worker_manifests[0]}"
grep -q 'subPath: codex-home' "${worker_manifests[0]}"
grep -A8 'readinessProbe:' "${worker_manifests[0]}" | grep -q 'timeoutSeconds: 5'

echo "worker authentication tests passed"
