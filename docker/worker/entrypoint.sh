#!/usr/bin/env bash
set -euo pipefail

SYMPHONY_HOME="${SYMPHONY_HOME:-/home/symphony}"
SYMPHONY_WORKSPACE_ROOT="${SYMPHONY_WORKSPACE_ROOT:-/srv/symphony/workspaces}"
ARRUSTED_REPOSITORY_URL="${ARRUSTED_REPOSITORY_URL:-https://github.com/withAutograph/arrusted-development.git}"
GITHUB_MACHINE_LOGIN="autograph-symphony"
GITHUB_MACHINE_NAME="autograph-symphony"
GITHUB_MACHINE_EMAIL="jason+symphony@withgraph.com"
CODEX_AUTH_SOURCE="${CODEX_AUTH_SOURCE:-/etc/symphony/codex-auth/auth.json}"

trim_secret() {
  local name="$1" value
  value="${!name:-}"
  value="$(printf '%s' "$value" | tr -d '\r\n')"
  [[ -n "$value" ]] || { echo "$name is required" >&2; exit 1; }
  export "$name=$value"
}

verify_required_commands() {
  local command_name
  for command_name in bash codex curl gh git jq mise sshd timeout unzip zip; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      echo "required worker command is unavailable: $command_name" >&2
      return 1
    fi
  done
}

ensure_runtime_permissions() {
  install -d -m 0755 -o symphony -g symphony \
    "$SYMPHONY_HOME/.local" \
    "$SYMPHONY_HOME/.local/share" \
    "$SYMPHONY_HOME/.local/share/mise" \
    "$SYMPHONY_HOME/.local/state" \
    "$SYMPHONY_HOME/.local/state/mise"
  chown -R symphony:symphony \
    "$SYMPHONY_HOME/.local" \
    "$SYMPHONY_HOME/.codex"
}

synchronize_codex_auth() {
  local auth_target="$SYMPHONY_HOME/.codex/auth.json"
  local auth_temporary="$auth_target.next"

  if [[ ! -s "$CODEX_AUTH_SOURCE" ]]; then
    echo "canonical Codex ChatGPT authentication is unavailable" >&2
    return 1
  fi
  install -d -m 0700 -o symphony -g symphony "$SYMPHONY_HOME/.codex"
  cp "$CODEX_AUTH_SOURCE" "$auth_temporary"
  chown symphony:symphony "$auth_temporary"
  chmod 0600 "$auth_temporary"
  mv "$auth_temporary" "$auth_target"
}

configure_github_auth() {
  local authenticated_login configured_name configured_email gh_hosts_file

  trim_secret GITHUB_TOKEN

  install -d -m 0700 -o symphony -g symphony \
    "$SYMPHONY_HOME" "$SYMPHONY_HOME/.config" "$SYMPHONY_HOME/.config/gh"
  umask 077
  printf 'machine github.com\nlogin x-access-token\npassword %s\n' "$GITHUB_TOKEN" \
    > "$SYMPHONY_HOME/.netrc"
  chown symphony:symphony "$SYMPHONY_HOME/.netrc"
  chmod 0600 "$SYMPHONY_HOME/.netrc"

  printf '%s' "$GITHUB_TOKEN" | runuser -u symphony -- \
    env -u GITHUB_TOKEN -u GH_TOKEN HOME="$SYMPHONY_HOME" \
    gh auth login --hostname github.com --git-protocol https --with-token
  gh_hosts_file="$SYMPHONY_HOME/.config/gh/hosts.yml"
  chown symphony:symphony "$gh_hosts_file"
  chmod 0600 "$gh_hosts_file"

  runuser -u symphony -- env -u GITHUB_TOKEN -u GH_TOKEN HOME="$SYMPHONY_HOME" \
    gh auth status --hostname github.com >/dev/null
  authenticated_login="$(runuser -u symphony -- \
    env -u GITHUB_TOKEN -u GH_TOKEN HOME="$SYMPHONY_HOME" \
    gh api user --jq .login)"
  if [[ "$authenticated_login" != "$GITHUB_MACHINE_LOGIN" ]]; then
    echo "GitHub credential is not the required Symphony machine identity" >&2
    return 1
  fi

  if ! runuser -u symphony -- \
    env -u GITHUB_TOKEN -u GH_TOKEN HOME="$SYMPHONY_HOME" \
    gh repo view withAutograph/arrusted-development \
      --json nameWithOwner --jq .nameWithOwner >/dev/null; then
    echo "GitHub machine credential cannot access the required repository" >&2
    return 1
  fi
  if ! runuser -u symphony -- env HOME="$SYMPHONY_HOME" \
    git ls-remote --exit-code "$ARRUSTED_REPOSITORY_URL" HEAD >/dev/null; then
    echo "Git HTTPS cannot access the required repository" >&2
    return 1
  fi

  runuser -u symphony -- env HOME="$SYMPHONY_HOME" \
    git config --global user.name "$GITHUB_MACHINE_NAME"
  runuser -u symphony -- env HOME="$SYMPHONY_HOME" \
    git config --global user.email "$GITHUB_MACHINE_EMAIL"
  runuser -u symphony -- env HOME="$SYMPHONY_HOME" \
    git config --global user.useConfigOnly true

  configured_name="$(runuser -u symphony -- env HOME="$SYMPHONY_HOME" \
    git config --global --get user.name)"
  configured_email="$(runuser -u symphony -- env HOME="$SYMPHONY_HOME" \
    git config --global --get user.email)"
  if [[ "$configured_name" != "$GITHUB_MACHINE_NAME" || \
        "$configured_email" != "$GITHUB_MACHINE_EMAIL" ]]; then
    echo "Git author identity does not match the required Symphony machine identity" >&2
    return 1
  fi

}

verify_sshd_git_identity() {
  local effective_setenv expected

  effective_setenv="$(sshd -T | awk '
    $1 == "setenv" {
      for (field = 2; field <= NF; field += 1) print $field
    }
  ')"
  for expected in \
    "GIT_AUTHOR_NAME=$GITHUB_MACHINE_NAME" \
    "GIT_AUTHOR_EMAIL=$GITHUB_MACHINE_EMAIL" \
    "GIT_COMMITTER_NAME=$GITHUB_MACHINE_NAME" \
    "GIT_COMMITTER_EMAIL=$GITHUB_MACHINE_EMAIL"; do
    if ! grep -Fqx "$expected" <<<"$effective_setenv"; then
      echo "sshd does not enforce the required Git machine identity" >&2
      return 1
    fi
  done
}

verify_codex_chatgpt_auth() {
  local login_status
  login_status="$(runuser -u symphony -- env HOME=/home/symphony codex login status 2>&1 || true)"
  if [[ "$login_status" != *"Logged in using ChatGPT"* ]]; then
    echo "Codex ChatGPT authentication is required; API-key fallback is disabled" >&2
    return 1
  fi
}

verify_codex_chatgpt_session() {
  local probe_output

  if ! probe_output="$(runuser -u symphony -- \
    env HOME="$SYMPHONY_HOME" \
    timeout 60s \
    codex exec \
      --skip-git-repo-check \
      --sandbox read-only \
      --color never \
      "Reply with exactly OK." 2>&1)"; then
    echo "Codex ChatGPT session could not complete an authenticated request" >&2
    return 1
  fi

  if ! grep -Fxq "OK" <<<"$probe_output"; then
    echo "Codex ChatGPT session probe returned an unexpected response" >&2
    return 1
  fi
}

ensure_codex_chatgpt_session() {
  if verify_codex_chatgpt_auth && verify_codex_chatgpt_session; then
    return 0
  fi

  echo "Persisted Codex ChatGPT session is unusable; restoring canonical authentication" >&2
  synchronize_codex_auth
  verify_codex_chatgpt_auth
  verify_codex_chatgpt_session
}

install_workspace_branch_guards() {
  local workspace

  while IFS= read -r -d '' workspace; do
    if [[ -e "$workspace/.git" ]]; then
      runuser -u symphony -- env \
        HOME="$SYMPHONY_HOME" \
        SYMPHONY_WORKSPACE_ROOT="$SYMPHONY_WORKSPACE_ROOT" \
        /usr/local/bin/install-workspace-branch-guard "$workspace"
    fi
  done < <(find "$SYMPHONY_WORKSPACE_ROOT" -mindepth 1 -maxdepth 1 -type d -print0)
}

main() {
trim_secret LINEAR_API_KEY
verify_required_commands
ensure_runtime_permissions
configure_github_auth
verify_sshd_git_identity
ensure_codex_chatgpt_session

mkdir -p "$SYMPHONY_WORKSPACE_ROOT" "$SYMPHONY_HOME/.ssh" /run/sshd
chown symphony:symphony "$SYMPHONY_WORKSPACE_ROOT"
chmod 0777 "$SYMPHONY_WORKSPACE_ROOT"
chown symphony:symphony "$SYMPHONY_HOME" "$SYMPHONY_HOME/.ssh"
install_workspace_branch_guards

if [[ -f /etc/ssh/authorized-keys/authorized_keys ]]; then
  cp /etc/ssh/authorized-keys/authorized_keys "$SYMPHONY_HOME/.ssh/authorized_keys"
  chown symphony:symphony "$SYMPHONY_HOME/.ssh/authorized_keys"
  chmod 600 "$SYMPHONY_HOME/.ssh/authorized_keys"
fi

chmod 700 "$SYMPHONY_HOME/.ssh"
touch /run/symphony-worker-ready

exec /usr/sbin/sshd -D -e
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
