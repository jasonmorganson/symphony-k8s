#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
entrypoint="$ROOT_DIR/docker/worker/entrypoint.sh"
workflow="$ROOT_DIR/config/workflow-runtime.yaml"

grep -Fq 'env -u LINEAR_API_KEY -u LINEAR_TOKEN -u TRACKER_TOKEN /usr/local/bin/symphony-session-supervisor client -- codex' "$workflow"
[[ "$(grep -Fc '/usr/local/bin/symphony-session-supervisor client --' "$workflow")" -eq 3 ]]
grep -Fq 'env -u LINEAR_API_KEY -u LINEAR_TOKEN -u TRACKER_TOKEN -u GITHUB_TOKEN -u GH_TOKEN' "$entrypoint"
grep -Fq '/usr/local/bin/symphony-session-supervisor daemon &' "$entrypoint"
# Match literal shell source rather than expanding the test process variables.
# shellcheck disable=SC2016
grep -Fq 'wait -n "$supervisor_pid" "$sshd_pid"' "$entrypoint"
grep -Fq 'install -d -m 0750 -o root -g symphony /run/symphony' "$entrypoint"
grep -Fq 'touch /run/symphony-worker-ready' "$entrypoint"

echo "session supervisor contract tests passed"
