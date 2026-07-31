#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: verify-symphony-upstream.sh SYMPHONY_CHECKOUT FORK_REVISION UPSTREAM_REVISION APPROVED_PATCH" >&2
  exit 64
fi

checkout="$1"
fork_revision="$2"
upstream_revision="$3"
approved_patch="$4"
actual="$(git -C "$checkout" rev-parse HEAD)"
[[ "$actual" == "$fork_revision" ]] || { echo "unexpected Symphony fork revision: $actual" >&2; exit 1; }
git -C "$checkout" fetch --quiet upstream "$upstream_revision"
[[ "$(git -C "$checkout" rev-parse FETCH_HEAD)" == "$upstream_revision" ]] || { echo "pinned commit is absent from upstream" >&2; exit 1; }
actual_patch="$(mktemp)"
trap 'rm -f "$actual_patch"' EXIT
git -C "$checkout" diff --binary --full-index "FETCH_HEAD^{tree}" "HEAD^{tree}" >"$actual_patch"
cmp --silent "$approved_patch" "$actual_patch" || {
  echo "Symphony fork differs from the sole approved production patch" >&2
  diff -u "$approved_patch" "$actual_patch" || true
  exit 1
}

if grep -E '^\+[^+]' "$actual_patch" | grep -Eiq 'Arrusted|Human Review|Merging|Rework|Todo|In Progress'; then
  echo "workflow-specific behavior is forbidden in the Symphony fork patch" >&2
  exit 1
fi
