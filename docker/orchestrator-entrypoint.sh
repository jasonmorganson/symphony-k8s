#!/usr/bin/env sh
set -eu

if ! codex login status >/dev/null 2>&1; then
  if [ -n "${OPENAI_API_KEY:-}" ]; then
    printf '%s\n' "$OPENAI_API_KEY" | codex login --with-api-key >/dev/null
  else
    echo "OPENAI_API_KEY is required for Codex login" >&2
    exit 1
  fi
fi

exec /app/bin/symphony "$@"
