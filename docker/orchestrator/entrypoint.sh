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

exec /app/bin/symphony "$@"
