#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../docker/worker/entrypoint.sh
source "$ROOT_DIR/docker/worker/entrypoint.sh"

assert_required_commands() {
  local missing="${1:-}" output rc=0
  command() {
    if [[ "${2:-}" == "$missing" ]]; then
      return 1
    fi
    return 0
  }
  output="$(verify_required_commands 2>&1)" || rc=$?
  if [[ -z "$missing" ]]; then
    [[ "$rc" -eq 0 && -z "$output" ]]
  else
    [[ "$rc" -ne 0 ]]
    [[ "$output" == *"required worker command is unavailable: $missing"* ]]
  fi
  unset -f command
}

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
assert_required_commands
assert_required_commands gh

assert_machine_identity_result() {
  local login="$1" expected="$2" repository_access="${3:-success}"
  local secret="machine-token-must-not-leak" output rc=0
  local tmp_home output_file
  tmp_home="$(mktemp -d)"
  output_file="$tmp_home/bootstrap.log"
  # These variables are consumed by functions sourced from the entrypoint.
  # shellcheck disable=SC2034
  SYMPHONY_HOME="$tmp_home"
  # shellcheck disable=SC2034
  GITHUB_TOKEN="$secret"

  install() { mkdir -p "$tmp_home/.config/gh"; }
  chown() { :; }
  chmod() { :; }
  runuser() {
    case "$*" in
      *"gh auth status"*) return 0 ;;
      *"gh api user"*) printf '%s\n' "$login" ;;
      *"gh repo view"*)
        [[ "$repository_access" == success ]] || return 1
        printf '%s\n' "withAutograph/arrusted-development"
        ;;
      *"git ls-remote"*) return 0 ;;
      *"git config --global user.name "*) return 0 ;;
      *"git config --global user.email "*) return 0 ;;
      *"git config --global user.useConfigOnly true"*) return 0 ;;
      *"git config --global --get user.name"*) printf '%s\n' "$GITHUB_MACHINE_NAME" ;;
      *"git config --global --get user.email"*) printf '%s\n' "$GITHUB_MACHINE_EMAIL" ;;
      *) echo "unexpected command" >&2; return 99 ;;
    esac
  }

  configure_github_auth >"$output_file" 2>&1 || rc=$?
  output="$(<"$output_file")"
  if [[ "$expected" == success ]]; then
    [[ "$rc" -eq 0 ]]
    [[ "$GIT_AUTHOR_NAME" == "$GITHUB_MACHINE_NAME" ]]
    [[ "$GIT_AUTHOR_EMAIL" == "$GITHUB_MACHINE_EMAIL" ]]
    [[ "$GIT_COMMITTER_NAME" == "$GITHUB_MACHINE_NAME" ]]
    [[ "$GIT_COMMITTER_EMAIL" == "$GITHUB_MACHINE_EMAIL" ]]
  else
    [[ "$rc" -ne 0 ]]
    if [[ "$repository_access" == failure ]]; then
      [[ "$output" == *"cannot access the required repository"* ]]
    else
      [[ "$output" == *"not the required Symphony machine identity"* ]]
    fi
  fi
  [[ "$output" != *"$secret"* ]]
  local netrc_mode
  netrc_mode="$(stat -c '%a' "$tmp_home/.netrc" 2>/dev/null || \
    stat -f '%Lp' "$tmp_home/.netrc")"
  [[ "$netrc_mode" == 600 ]]

  unset -f install chown chmod runuser
  unset GITHUB_TOKEN GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL
  unset GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
  rm -rf "$tmp_home"
}

assert_machine_identity_result "autograph-symphony" success
assert_machine_identity_result "jasonmorganson" failure
assert_machine_identity_result "autograph-symphony" failure failure

unset GITHUB_TOKEN
missing_rc=0
missing_output="$(trim_secret GITHUB_TOKEN 2>&1)" || missing_rc=$?
[[ "$missing_rc" -ne 0 ]]
[[ "$missing_output" == *"GITHUB_TOKEN is required"* ]]

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
grep -A8 'readinessProbe:' "${worker_manifests[0]}" | grep -q '/run/symphony-worker-ready'

grep -q '^    gh \\' "$ROOT_DIR/docker/worker/Dockerfile"
grep -q 'gh --version' "$ROOT_DIR/docker/worker/Dockerfile"
grep -q 'configure_github_auth' "$ROOT_DIR/docker/worker/entrypoint.sh"
grep -q 'gh auth status --hostname github.com' "$ROOT_DIR/docker/worker/entrypoint.sh"
grep -q 'gh api user --jq .login' "$ROOT_DIR/docker/worker/entrypoint.sh"
grep -q 'GITHUB_MACHINE_LOGIN="autograph-symphony"' "$ROOT_DIR/docker/worker/entrypoint.sh"
grep -q 'GITHUB_MACHINE_EMAIL="jason+symphony@withgraph.com"' "$ROOT_DIR/docker/worker/entrypoint.sh"
grep -q 'git config --global user.useConfigOnly true' "$ROOT_DIR/docker/worker/entrypoint.sh"
grep -q 'export GIT_COMMITTER_NAME="$GITHUB_MACHINE_NAME"' \
  "$ROOT_DIR/docker/worker/entrypoint.sh"
grep -q 'git ls-remote --exit-code' "$ROOT_DIR/docker/worker/entrypoint.sh"
grep -A5 'name: GITHUB_TOKEN' "${worker_manifests[0]}" | \
  grep -q 'name: github-machine-arrusted-symphony'
grep -A5 'name: GITHUB_TOKEN' "${worker_manifests[0]}" | grep -q 'key: token'

if grep -A5 'name: GITHUB_TOKEN' "${worker_manifests[0]}" | \
  grep -q 'name: symphony-secrets'; then
  echo "worker still sources GitHub auth from the shared or legacy secret" >&2
  exit 1
fi

if grep -A6 'key: GITHUB_TOKEN' "${worker_manifests[0]}" | grep -q 'optional: true'; then
  echo "worker GitHub credential must fail closed" >&2
  exit 1
fi

echo "worker authentication tests passed"
