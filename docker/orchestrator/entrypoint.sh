#!/usr/bin/env sh
set -eu

trim_secret() {
  name="$1"
  eval "value=\${$name:-}"
  value="$(printf '%s' "$value" | tr -d '\r\n')"
  test -n "$value" || { echo "$name is required" >&2; exit 1; }
  export "$name=$value"
}

trim_secret LINEAR_API_KEY
trim_secret OPENAI_API_KEY

if [ -n "${GITHUB_TOKEN:-}" ]; then
  trim_secret GITHUB_TOKEN
  git config --global url."https://x-access-token:${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/"
  git config --global --add url."https://x-access-token:${GITHUB_TOKEN}@github.com/".insteadOf "git@github.com:"
  git config --global --add url."https://x-access-token:${GITHUB_TOKEN}@github.com/".insteadOf "ssh://git@github.com/"
fi

if ! codex login status >/dev/null 2>&1; then
  if [ -n "${OPENAI_API_KEY:-}" ]; then
    printf '%s\n' "$OPENAI_API_KEY" | codex login --with-api-key >/dev/null
  else
    echo "OPENAI_API_KEY is required for Codex login" >&2
    exit 1
  fi
fi

exec /app/bin/symphony "$@"
