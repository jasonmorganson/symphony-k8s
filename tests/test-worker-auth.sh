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
assert_required_commands timeout

assert_session_result() {
  local mode="$1" expected="$2" output rc=0
  runuser() {
    if [[ "$*" != *"codex exec"* ]]; then
      echo "unexpected command: $*" >&2
      return 99
    fi
    case "$mode" in
      success) printf '%s\n' "OK" ;;
      unexpected) printf '%s\n' "not ok" ;;
      failure) return 1 ;;
    esac
  }
  output="$(verify_codex_chatgpt_session 2>&1)" || rc=$?
  if [[ "$expected" == success ]]; then
    [[ "$rc" -eq 0 && -z "$output" ]]
  else
    [[ "$rc" -ne 0 ]]
    [[ "$output" == *"Codex ChatGPT session"* ]]
  fi
  unset -f runuser
}

assert_session_result success success
assert_session_result unexpected failure
assert_session_result failure failure

assert_codex_auth_sync() {
  local tmp source_auth target_auth mode
  tmp="$(mktemp -d)"
  source_auth="$tmp/source.json"
  SYMPHONY_HOME="$tmp/home"
  export CODEX_AUTH_SOURCE="$source_auth"
  mkdir -p "$SYMPHONY_HOME/.codex"
  printf '%s\n' '{"canonical":"new"}' > "$source_auth"
  printf '%s\n' '{"stale":"old"}' > "$SYMPHONY_HOME/.codex/auth.json"
  install() {
    mkdir -p "${*: -1}"
    chmod 0700 "${*: -1}"
  }
  chown() { :; }

  synchronize_codex_auth

  target_auth="$SYMPHONY_HOME/.codex/auth.json"
  cmp -s "$source_auth" "$target_auth"
  [[ ! -e "$target_auth.next" ]]
  mode="$(stat -c '%a' "$target_auth" 2>/dev/null || stat -f '%Lp' "$target_auth")"
  [[ "$mode" == 600 ]]

  : > "$source_auth"
  if synchronize_codex_auth 2>"$tmp/error.log"; then
    echo "empty canonical Codex auth must fail closed" >&2
    return 1
  fi
  grep -q 'canonical Codex ChatGPT authentication is unavailable' "$tmp/error.log"
  unset -f install chown
  unset CODEX_AUTH_SOURCE
  rm -rf "$tmp"
}

assert_codex_auth_sync

assert_codex_recovery() {
  local mode="$1" expected_syncs="$2" tmp syncs=0
  tmp="$(mktemp -d)"
  verify_codex_chatgpt_auth() {
    [[ "$mode" != broken || -s "$tmp/restored" ]]
  }
  verify_codex_chatgpt_session() {
    [[ "$mode" != broken || -s "$tmp/restored" ]]
  }
  synchronize_codex_auth() {
    printf '%s\n' restored > "$tmp/restored"
    printf '%s\n' sync >> "$tmp/syncs"
  }

  ensure_codex_chatgpt_session 2>"$tmp/error.log"

  if [[ -f "$tmp/syncs" ]]; then
    syncs="$(wc -l < "$tmp/syncs" | tr -d '[:space:]')"
  fi
  [[ "$syncs" == "$expected_syncs" ]]
  if [[ "$mode" == broken ]]; then
    grep -q 'restoring canonical authentication' "$tmp/error.log"
  else
    [[ ! -s "$tmp/error.log" ]]
  fi
  unset -f verify_codex_chatgpt_auth verify_codex_chatgpt_session synchronize_codex_auth
  rm -rf "$tmp"
}

assert_codex_recovery healthy 0
assert_codex_recovery broken 1

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
      *"gh auth login"*)
        cat >/dev/null
        printf '%s\n' 'github.com:' > "$tmp_home/.config/gh/hosts.yml"
        ;;
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
  else
    [[ "$rc" -ne 0 ]]
    if [[ "$repository_access" == failure ]]; then
      [[ "$output" == *"cannot access the required repository"* ]]
    else
      [[ "$output" == *"not the required Symphony machine identity"* ]]
    fi
  fi
  [[ "$output" != *"$secret"* ]]
  local netrc_mode hosts_mode
  netrc_mode="$(stat -c '%a' "$tmp_home/.netrc" 2>/dev/null || \
    stat -f '%Lp' "$tmp_home/.netrc")"
  [[ "$netrc_mode" == 600 ]]
  hosts_mode="$(stat -c '%a' "$tmp_home/.config/gh/hosts.yml" 2>/dev/null || \
    stat -f '%Lp' "$tmp_home/.config/gh/hosts.yml")"
  [[ "$hosts_mode" == 600 ]]

  unset -f install chown chmod runuser
  unset GITHUB_TOKEN
  rm -rf "$tmp_home"
}

assert_machine_identity_result "autograph-symphony" success
assert_machine_identity_result "jasonmorganson" failure
assert_machine_identity_result "autograph-symphony" failure failure

assert_sshd_identity_result() {
  local mode="$1" expected="$2" output rc=0
  sshd() {
    [[ "${1:-}" == -T ]] || return 99
    if [[ "$mode" == complete ]]; then
      cat <<EOF
setenv GIT_AUTHOR_NAME=$GITHUB_MACHINE_NAME GIT_AUTHOR_EMAIL=$GITHUB_MACHINE_EMAIL
setenv GIT_COMMITTER_NAME=$GITHUB_MACHINE_NAME GIT_COMMITTER_EMAIL=$GITHUB_MACHINE_EMAIL
EOF
    else
      printf '%s\n' "setenv GIT_AUTHOR_NAME=$GITHUB_MACHINE_NAME"
    fi
  }

  output="$(verify_sshd_git_identity 2>&1)" || rc=$?
  if [[ "$expected" == success ]]; then
    [[ "$rc" -eq 0 && -z "$output" ]]
  else
    [[ "$rc" -ne 0 ]]
    [[ "$output" == *"sshd does not enforce the required Git machine identity"* ]]
  fi
  unset -f sshd
}

assert_sshd_identity_result complete success
assert_sshd_identity_result incomplete failure

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
if grep -A8 'readinessProbe:' "${worker_manifests[0]}" | grep -q 'codex login status'; then
  echo "worker readiness still trusts the non-validating Codex login status" >&2
  exit 1
fi

grep -q '^    gh \\' "$ROOT_DIR/docker/worker/Dockerfile"
grep -q 'gh --version' "$ROOT_DIR/docker/worker/Dockerfile"
grep -q 'configure_github_auth' "$ROOT_DIR/docker/worker/entrypoint.sh"
grep -q 'gh auth login --hostname github.com --git-protocol https --with-token' \
  "$ROOT_DIR/docker/worker/entrypoint.sh"
grep -q 'env -u GITHUB_TOKEN -u GH_TOKEN HOME=' \
  "$ROOT_DIR/docker/worker/entrypoint.sh"
grep -q 'gh auth status --hostname github.com' "$ROOT_DIR/docker/worker/entrypoint.sh"
grep -q 'gh api user --jq .login' "$ROOT_DIR/docker/worker/entrypoint.sh"
grep -q 'GITHUB_MACHINE_LOGIN="autograph-symphony"' "$ROOT_DIR/docker/worker/entrypoint.sh"
grep -q 'GITHUB_MACHINE_EMAIL="jason+symphony@withgraph.com"' "$ROOT_DIR/docker/worker/entrypoint.sh"
grep -q 'git config --global user.useConfigOnly true' "$ROOT_DIR/docker/worker/entrypoint.sh"
grep -q 'verify_sshd_git_identity' "$ROOT_DIR/docker/worker/entrypoint.sh"
grep -q 'verify_codex_chatgpt_session' "$ROOT_DIR/docker/worker/entrypoint.sh"
grep -q 'ensure_codex_chatgpt_session' "$ROOT_DIR/docker/worker/entrypoint.sh"
grep -q 'ensure_runtime_permissions' "$ROOT_DIR/docker/worker/entrypoint.sh"
grep -q 'synchronize_codex_auth' "$ROOT_DIR/docker/worker/entrypoint.sh"
grep -q 'chown -R symphony:symphony' "$ROOT_DIR/docker/worker/entrypoint.sh"
grep -q 'Codex ChatGPT session could not complete an authenticated request' \
  "$ROOT_DIR/docker/worker/entrypoint.sh"
grep -q 'if \[ ! -s /srv/worker-data/codex-home/auth.json \]; then' \
  "${worker_manifests[0]}"
grep -q 'cp /codex-auth/auth.json /srv/worker-data/codex-home/auth.json.next' \
  "${worker_manifests[0]}"
grep -q 'mountPath: /home/symphony/.local' "${worker_manifests[0]}"
grep -q 'mountPath: /etc/symphony/codex-auth' "${worker_manifests[0]}"
grep -q 'git ls-remote --exit-code' "$ROOT_DIR/docker/worker/entrypoint.sh"
sshd_config="$ROOT_DIR/config/sshd_config.d/worker.conf"
setenv_line='SetEnv GIT_AUTHOR_NAME=autograph-symphony GIT_AUTHOR_EMAIL=jason+symphony@withgraph.com GIT_COMMITTER_NAME=autograph-symphony GIT_COMMITTER_EMAIL=jason+symphony@withgraph.com'
grep -Fqx "$setenv_line" "$sshd_config"
grep -A5 'name: GITHUB_TOKEN' "${worker_manifests[0]}" | \
  grep -q 'name: github-machine-arrusted-symphony'
grep -A5 'name: GITHUB_TOKEN' "${worker_manifests[0]}" | grep -q 'key: token'

if grep -A5 'name: GITHUB_TOKEN' "${worker_manifests[0]}" | \
  grep -q 'name: symphony-secrets'; then
  echo "worker still sources GitHub auth from the shared or legacy secret" >&2
  exit 1
fi

grep -A6 'name: GITHUB_TOKEN' "${worker_manifests[0]}" | grep -q 'optional: false'

echo "worker authentication tests passed"
