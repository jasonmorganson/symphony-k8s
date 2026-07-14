#!/usr/bin/env bash
set -euo pipefail

SYMPHONY_HOME="${SYMPHONY_HOME:-/home/symphony}"
SYMPHONY_WORKSPACE_ROOT="${SYMPHONY_WORKSPACE_ROOT:-/srv/symphony/workspaces}"
ARRUSTED_REPOSITORY_URL="${ARRUSTED_REPOSITORY_URL:-https://github.com/withAutograph/arrusted-development.git}"
GITHUB_MACHINE_LOGIN="autograph-symphony"
GITHUB_MACHINE_NAME="autograph-symphony"
GITHUB_MACHINE_EMAIL="jason+symphony@withgraph.com"

trim_secret() {
  local name="$1" value
  value="${!name:-}"
  value="$(printf '%s' "$value" | tr -d '\r\n')"
  [[ -n "$value" ]] || { echo "$name is required" >&2; exit 1; }
  export "$name=$value"
}

verify_required_commands() {
  local command_name
  for command_name in bash codex curl gh git mise sshd; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      echo "required worker command is unavailable: $command_name" >&2
      return 1
    fi
  done
}

configure_github_auth() {
  local authenticated_login configured_name configured_email

  trim_secret GITHUB_TOKEN

  install -d -m 0700 -o symphony -g symphony \
    "$SYMPHONY_HOME" "$SYMPHONY_HOME/.config" "$SYMPHONY_HOME/.config/gh"
  umask 077
  printf 'machine github.com\nlogin x-access-token\npassword %s\n' "$GITHUB_TOKEN" \
    > "$SYMPHONY_HOME/.netrc"
  chown symphony:symphony "$SYMPHONY_HOME/.netrc"
  chmod 0600 "$SYMPHONY_HOME/.netrc"

  runuser -u symphony -- env HOME="$SYMPHONY_HOME" \
    gh auth status --hostname github.com >/dev/null
  authenticated_login="$(runuser -u symphony -- env HOME="$SYMPHONY_HOME" \
    gh api user --jq .login)"
  if [[ "$authenticated_login" != "$GITHUB_MACHINE_LOGIN" ]]; then
    echo "GitHub credential is not the required Symphony machine identity" >&2
    return 1
  fi

  if ! runuser -u symphony -- env HOME="$SYMPHONY_HOME" \
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

  # SSH commands inherit these values from sshd, so a workspace-local Git
  # config cannot silently replace the machine author or committer.
  export GIT_AUTHOR_NAME="$GITHUB_MACHINE_NAME"
  export GIT_AUTHOR_EMAIL="$GITHUB_MACHINE_EMAIL"
  export GIT_COMMITTER_NAME="$GITHUB_MACHINE_NAME"
  export GIT_COMMITTER_EMAIL="$GITHUB_MACHINE_EMAIL"
}

verify_codex_chatgpt_auth() {
  local login_status
  login_status="$(runuser -u symphony -- env HOME=/home/symphony codex login status 2>&1 || true)"
  if [[ "$login_status" != *"Logged in using ChatGPT"* ]]; then
    echo "Codex ChatGPT authentication is required; API-key fallback is disabled" >&2
    return 1
  fi
}

main() {
trim_secret LINEAR_API_KEY
verify_required_commands
configure_github_auth
verify_codex_chatgpt_auth

mkdir -p "$SYMPHONY_WORKSPACE_ROOT" "$SYMPHONY_HOME/.ssh" /run/sshd
chown -R symphony:symphony "$SYMPHONY_WORKSPACE_ROOT"
chmod 0777 "$SYMPHONY_WORKSPACE_ROOT"
chown symphony:symphony "$SYMPHONY_HOME" "$SYMPHONY_HOME/.ssh"

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
