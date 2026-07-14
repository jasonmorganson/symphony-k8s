#!/usr/bin/env bash
set -euo pipefail

workspace_root="${SYMPHONY_WORKSPACE_ROOT:-/srv/symphony/workspaces}"
workspace="${1:-$PWD}"
repository_url="${ARRUSTED_REPOSITORY_URL:-https://github.com/withAutograph/arrusted-development.git}"
git_bin="${GIT_BIN:-git}"
mise_bin="${MISE_BIN:-mise}"

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

"$git_bin" clone --filter=blob:none "$repository_url" "$workspace"

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

trap - EXIT
