#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: verify-symphony-upstream.sh SYMPHONY_CHECKOUT FORK_REVISION UPSTREAM_REVISION APPROVED_PATCH" >&2
  exit 64
fi

checkout="$1"
fork_revision="$2"
upstream_revision="$3"
approved_patch="$(cd "$(dirname "$4")" && pwd)/$(basename "$4")"
actual="$(git -C "$checkout" rev-parse HEAD)"
[[ "$actual" == "$fork_revision" ]] || { echo "unexpected Symphony fork revision: $actual" >&2; exit 1; }
git -C "$checkout" fetch --quiet upstream "$upstream_revision"
[[ "$(git -C "$checkout" rev-parse FETCH_HEAD)" == "$upstream_revision" ]] || { echo "pinned commit is absent from upstream" >&2; exit 1; }
approved_worktree="$(mktemp -d)"
rmdir "$approved_worktree"
cleanup() {
  git -C "$checkout" worktree remove --force "$approved_worktree" >/dev/null 2>&1 || true
}
trap cleanup EXIT
git -C "$checkout" worktree add --quiet --detach "$approved_worktree" FETCH_HEAD
git -C "$approved_worktree" apply --index "$approved_patch"
approved_tree="$(git -C "$approved_worktree" write-tree)"
fork_tree="$(git -C "$checkout" rev-parse 'HEAD^{tree}')"
[[ "$approved_tree" == "$fork_tree" ]] || {
  echo "Symphony fork differs from the sole approved production patch" >&2
  exit 1
}

if grep -E '^\+[^+]' "$approved_patch" | grep -Eiq 'Arrusted|Human Review|Merging|Rework|Todo|In Progress'; then
  echo "workflow-specific behavior is forbidden in the Symphony fork patch" >&2
  exit 1
fi
