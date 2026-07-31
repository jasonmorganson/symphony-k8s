#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../docker/worker/entrypoint.sh
source "$ROOT_DIR/docker/worker/entrypoint.sh"

assert_required_command() {
  local missing="$1" rc=0
  command() { [[ "${2:-}" != "$missing" ]]; }
  verify_required_commands >/dev/null 2>&1 || rc=$?
  unset -f command
  [[ "$rc" -ne 0 ]]
}

for utility in gh git jq mise sshd unzip zip; do
  assert_required_command "$utility"
done

runuser() { printf '%s\n' "Logged in using ChatGPT"; }
verify_codex_chatgpt_auth
runuser() { printf '%s\n' "Logged in using an API key"; }
if verify_codex_chatgpt_auth >/dev/null 2>&1; then
  echo "worker accepted API-key Codex authentication" >&2
  exit 1
fi
unset -f runuser

manifest="$ROOT_DIR/k8s/base/worker-statefulset.yaml"
grep -q 'secretName: codex-chatgpt-auth' "$manifest"
grep -q 'name: github-machine-arrusted-symphony' "$manifest"
grep -q 'name: workspaces' "$manifest"
if grep -Eq 'volumeClaimTemplates|workspace-reclaimer|affinity_state|drain_state' "$manifest"; then
  echo "worker retained authoritative workspace or scheduler state" >&2
  exit 1
fi
if grep -Eq 'codex login --with-api-key|trim_secret OPENAI_API_KEY' "$ROOT_DIR/docker/worker/entrypoint.sh"; then
  echo "worker entrypoint contains an API-key fallback" >&2
  exit 1
fi
if grep -Eq 'withAutograph|arrusted|autograph-symphony' "$ROOT_DIR/docker/worker/entrypoint.sh"; then
  echo "generic worker image contains repository-specific policy" >&2
  exit 1
fi
grep -Fq 'url.https://github.com/.insteadOf git@github.com:' \
  "$ROOT_DIR/docker/worker/entrypoint.sh"

echo "worker authentication and ephemerality contract is valid"
