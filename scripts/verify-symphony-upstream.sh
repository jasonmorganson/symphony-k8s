#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: verify-symphony-upstream.sh SYMPHONY_CHECKOUT FORK_REVISION UPSTREAM_REVISION" >&2
  exit 64
fi

checkout="$1"
fork_revision="$2"
upstream_revision="$3"
actual="$(git -C "$checkout" rev-parse HEAD)"
[[ "$actual" == "$fork_revision" ]] || { echo "unexpected Symphony fork revision: $actual" >&2; exit 1; }
git -C "$checkout" fetch --quiet upstream "$upstream_revision"
[[ "$(git -C "$checkout" rev-parse FETCH_HEAD)" == "$upstream_revision" ]] || { echo "pinned commit is absent from upstream" >&2; exit 1; }
git -C "$checkout" diff --exit-code "FETCH_HEAD^{tree}" "HEAD^{tree}"
