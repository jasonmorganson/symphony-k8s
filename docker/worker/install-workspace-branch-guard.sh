#!/usr/bin/env bash
set -euo pipefail

workspace_root="${SYMPHONY_WORKSPACE_ROOT:-/srv/symphony/workspaces}"
workspace="${1:?workspace path is required}"
git_bin="${GIT_BIN:-git}"

workspace_root="$(cd "$workspace_root" && pwd -P)"
workspace="$(cd "$workspace" && pwd -P)"

case "$workspace/" in
  "$workspace_root"/*) ;;
  *)
    echo "refusing to guard a repository outside the Symphony workspace root: $workspace" >&2
    exit 1
    ;;
esac

issue_identifier="$(basename "$workspace")"
if [[ ! "$issue_identifier" =~ ^[A-Za-z]+-[0-9]+$ ]]; then
  echo "refusing to guard a workspace without an issue identifier: $workspace" >&2
  exit 1
fi

if ! "$git_bin" -C "$workspace" rev-parse --git-dir >/dev/null 2>&1; then
  echo "refusing to guard a workspace without a Git repository: $workspace" >&2
  exit 1
fi

hooks_dir="$("$git_bin" -C "$workspace" rev-parse --git-path hooks)"
case "$hooks_dir" in
  /*) ;;
  *) hooks_dir="$workspace/$hooks_dir" ;;
esac
mkdir -p "$hooks_dir"

hook="$hooks_dir/pre-push"
temporary="$(mktemp "$hooks_dir/.pre-push.XXXXXX")"
cleanup() {
  rm -f "$temporary"
}
trap cleanup EXIT

cat >"$temporary" <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail

workspace_root="${SYMPHONY_WORKSPACE_ROOT:-/srv/symphony/workspaces}"
workspace="$(git rev-parse --show-toplevel)"
workspace_root="$(cd "$workspace_root" && pwd -P)"
workspace="$(cd "$workspace" && pwd -P)"

case "$workspace/" in
  "$workspace_root"/*) ;;
  *)
    echo "Symphony branch guard refused a push outside the workspace root." >&2
    exit 1
    ;;
esac

issue_identifier="$(basename "$workspace")"
issue_token="$(printf '%s' "$issue_identifier" | tr '[:upper:]' '[:lower:]')"
zero_sha="0000000000000000000000000000000000000000"

while read -r _local_ref local_sha remote_ref _remote_sha; do
  [[ -n "${remote_ref:-}" ]] || continue

  case "$remote_ref" in
    refs/heads/*)
      branch="${remote_ref#refs/heads/}"
      normalized="$(printf '%s' "$branch" | tr '[:upper:]' '[:lower:]')"
      if [[ ! "$normalized" =~ (^|[/_-])${issue_token}([/_-]|$) ]]; then
        echo "Symphony branch ownership violation: $issue_identifier cannot push $branch." >&2
        echo "Use the branch owned by $issue_identifier; do not operate another issue's branch." >&2
        exit 1
      fi
      ;;
    *)
      if [[ "$local_sha" != "$zero_sha" ]]; then
        echo "Symphony branch ownership violation: issue workspaces may push branches only." >&2
        exit 1
      fi
      ;;
  esac
done
HOOK

chmod 0555 "$temporary"
mv -f "$temporary" "$hook"
trap - EXIT

