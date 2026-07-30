#!/usr/bin/env bash
set -euo pipefail

workspace_root="${SYMPHONY_WORKSPACE_ROOT:-/srv/symphony/workspaces}"
workspace="${1:-$PWD}"
repository_url="${ARRUSTED_REPOSITORY_URL:-https://github.com/withAutograph/arrusted-development.git}"
git_bin="${GIT_BIN:-git}"
mise_bin="${MISE_BIN:-mise}"
branch_guard_installer="${BRANCH_GUARD_INSTALLER:-/usr/local/bin/install-workspace-branch-guard}"
repository_cache="${SYMPHONY_REPOSITORY_CACHE:-${HOME:-/home/symphony}/.cache/symphony/arrusted-development.git}"

workspace_root="$(cd "$workspace_root" && pwd -P)"
workspace="$(cd "$workspace" && pwd -P)"

case "$workspace/" in
  "$workspace_root"/*) ;;
  *)
    echo "refusing to bootstrap outside the Symphony workspace root: $workspace" >&2
    exit 1
    ;;
esac

if [[ -n "$(find "$workspace" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  echo "refusing to bootstrap a non-empty workspace: $workspace" >&2
  exit 1
fi

cleanup_partial_checkout() {
  local status=$?
  if [[ "$status" -ne 0 ]]; then
    find "$workspace" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
    echo "workspace bootstrap failed; removed the partial checkout" >&2
  fi
  exit "$status"
}
trap cleanup_partial_checkout EXIT

prepare_repository_cache() {
  local cache_lock cache_parent cache_temporary

  cache_parent="$(dirname "$repository_cache")"
  cache_lock="${repository_cache}.lock"
  cache_temporary="${repository_cache}.new.$$"
  mkdir -p "$cache_parent"

  if mkdir "$cache_lock" 2>/dev/null; then
    if [[ -d "$repository_cache/objects" ]]; then
      if "$git_bin" -C "$repository_cache" remote set-url origin "$repository_url"; then
        "$git_bin" -C "$repository_cache" fetch \
          --prune --filter=blob:none origin \
          '+refs/heads/*:refs/heads/*' || \
          echo "repository cache refresh failed; using cached objects" >&2
      else
        echo "repository cache origin repair failed; using cached objects" >&2
      fi
    else
      if "$git_bin" clone --mirror --filter=blob:none "$repository_url" "$cache_temporary"; then
        if [[ ! -e "$repository_cache" ]]; then
          mv "$cache_temporary" "$repository_cache"
        else
          rm -rf -- "$cache_temporary"
        fi
      else
        rm -rf -- "$cache_temporary"
        echo "repository cache warmup failed; cloning directly" >&2
      fi
    fi
    rmdir "$cache_lock" || true
  fi

  [[ -d "$repository_cache/objects" ]]
}

if prepare_repository_cache; then
  "$git_bin" clone \
    --filter=blob:none \
    --reference-if-able "$repository_cache" \
    --dissociate \
    "$repository_url" \
    "$workspace"
else
  "$git_bin" clone --filter=blob:none "$repository_url" "$workspace"
fi

for required_path in AGENTS.md WORKFLOW.md docs/README.md; do
  if [[ ! -f "$workspace/$required_path" ]]; then
    echo "workspace checkout is missing required root file: $required_path" >&2
    exit 1
  fi
done

if [[ "$("$git_bin" -C "$workspace" remote get-url origin)" != "$repository_url" ]]; then
  echo "workspace checkout origin does not match the Arrusted repository" >&2
  exit 1
fi

cd "$workspace"
"$mise_bin" trust .
"$mise_bin" install

if [[ "${SKIP_WORKTRUNK_HOOKS:-false}" != true ]] && command -v wt >/dev/null 2>&1; then
  wt hook post-create --yes || echo "wt post-create hook not configured; skipping." >&2
  wt hook post-start --yes || echo "wt post-start hook not configured; skipping." >&2
fi

"$branch_guard_installer" "$workspace"

trap - EXIT
