#!/usr/bin/env bash
set -euo pipefail

trim_secret() {
  local name="$1" value
  value="${!name:-}"
  value="$(printf '%s' "$value" | tr -d '\r\n')"
  [[ -n "$value" ]] || { echo "$name is required" >&2; exit 1; }
  export "$name=$value"
}

trim_secret LINEAR_API_KEY
trim_secret OPENAI_API_KEY

if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  trim_secret GITHUB_TOKEN
  git config --global url."https://x-access-token:${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/"
  git config --global --add url."https://x-access-token:${GITHUB_TOKEN}@github.com/".insteadOf "git@github.com:"
  git config --global --add url."https://x-access-token:${GITHUB_TOKEN}@github.com/".insteadOf "ssh://git@github.com/"
fi

if ! runuser -u symphony -- codex login status >/dev/null 2>&1; then
  printf '%s\n' "$OPENAI_API_KEY" | runuser -u symphony -- codex login --with-api-key >/dev/null
fi

mkdir -p /srv/symphony/workspaces /home/symphony/.ssh /run/sshd
chown -R symphony:symphony /srv/symphony
chmod 0777 /srv/symphony/workspaces
chown symphony:symphony /home/symphony /home/symphony/.ssh

if [[ -f /etc/ssh/authorized-keys/authorized_keys ]]; then
  cp /etc/ssh/authorized-keys/authorized_keys /home/symphony/.ssh/authorized_keys
  chown symphony:symphony /home/symphony/.ssh/authorized_keys
  chmod 600 /home/symphony/.ssh/authorized_keys
fi

chmod 700 /home/symphony/.ssh

exec /usr/sbin/sshd -D -e
