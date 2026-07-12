#!/usr/bin/env bash
set -euo pipefail

trim_secret() {
  local name="$1" value
  value="${!name:-}"
  value="$(printf '%s' "$value" | tr -d '\r\n')"
  [[ -n "$value" ]] || { echo "$name is required" >&2; exit 1; }
  export "$name=$value"
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

if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  trim_secret GITHUB_TOKEN
  install -d -m 0700 -o symphony -g symphony /home/symphony
  printf 'machine github.com\nlogin x-access-token\npassword %s\n' "$GITHUB_TOKEN" \
    > /home/symphony/.netrc
  chown symphony:symphony /home/symphony/.netrc
  chmod 0600 /home/symphony/.netrc
fi

verify_codex_chatgpt_auth

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
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
