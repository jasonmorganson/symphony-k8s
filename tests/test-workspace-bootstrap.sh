#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bootstrap="$ROOT_DIR/docker/worker/bootstrap-arrusted-workspace.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fake_bin="$tmp/bin"
workspace_root="$tmp/workspaces"
mkdir -p "$fake_bin" "$workspace_root/success" "$workspace_root/failure" "$workspace_root/nonempty"

cat > "$fake_bin/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${FAIL_CLONE:-}" == 1 && "$1" == clone ]]; then
  mkdir -p "${@: -1}/partial"
  exit 42
fi
if [[ "$1" == clone ]]; then
  target="${@: -1}"
  mkdir -p "$target/.git" "$target/docs"
  touch "$target/AGENTS.md" "$target/WORKFLOW.md" "$target/docs/README.md"
  exit 0
fi
if [[ "$1" == -C && "$3" == remote && "$4" == get-url ]]; then
  printf '%s\n' "${ARRUSTED_REPOSITORY_URL:-https://github.com/withAutograph/arrusted-development.git}"
  exit 0
fi
exit 99
SH

cat > "$fake_bin/mise" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'mise %s\n' "$*" >> "${BOOTSTRAP_LOG:?}"
SH

chmod +x "$fake_bin/git" "$fake_bin/mise"

BOOTSTRAP_LOG="$tmp/bootstrap.log" \
GIT_BIN="$fake_bin/git" \
MISE_BIN="$fake_bin/mise" \
PATH="/usr/bin:/bin" \
SKIP_WORKTRUNK_HOOKS=true \
SYMPHONY_WORKSPACE_ROOT="$workspace_root" \
  "$bootstrap" "$workspace_root/success"

test -f "$workspace_root/success/AGENTS.md"
grep -q '^mise trust \.$' "$tmp/bootstrap.log"
grep -q '^mise install$' "$tmp/bootstrap.log"

rc=0
FAIL_CLONE=1 \
BOOTSTRAP_LOG="$tmp/bootstrap.log" \
GIT_BIN="$fake_bin/git" \
MISE_BIN="$fake_bin/mise" \
PATH="/usr/bin:/bin" \
SKIP_WORKTRUNK_HOOKS=true \
SYMPHONY_WORKSPACE_ROOT="$workspace_root" \
  "$bootstrap" "$workspace_root/failure" >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 42 ]]
[[ -z "$(find "$workspace_root/failure" -mindepth 1 -maxdepth 1 -print -quit)" ]]

touch "$workspace_root/nonempty/sentinel"
if BOOTSTRAP_LOG="$tmp/bootstrap.log" \
  GIT_BIN="$fake_bin/git" \
  MISE_BIN="$fake_bin/mise" \
  PATH="/usr/bin:/bin" \
  SKIP_WORKTRUNK_HOOKS=true \
  SYMPHONY_WORKSPACE_ROOT="$workspace_root" \
  "$bootstrap" "$workspace_root/nonempty" >/dev/null 2>&1; then
  echo "bootstrap accepted a non-empty workspace" >&2
  exit 1
fi
test -f "$workspace_root/nonempty/sentinel"

echo "workspace bootstrap tests passed"
