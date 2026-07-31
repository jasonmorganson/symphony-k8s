#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bootstrap="$ROOT_DIR/docker/worker/bootstrap-arrusted-workspace.sh"
branch_guard="$ROOT_DIR/docker/worker/install-workspace-branch-guard.sh"
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
  printf 'git %s\n' "$*" >> "${BOOTSTRAP_LOG:?}"
  if [[ " $* " == *" --mirror "* ]]; then
    mkdir -p "$target/objects"
    exit 0
  fi
  mkdir -p "$target/.git" "$target/docs"
  touch "$target/AGENTS.md" "$target/WORKFLOW.md" "$target/docs/README.md"
  exit 0
fi
if [[ "$1" == -C && "$3" == remote && "$4" == set-url ]]; then
  exit 0
fi
if [[ "$1" == -C && "$3" == fetch ]]; then
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

cat > "$fake_bin/branch-guard" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'guard %s\n' "$1" >> "${BOOTSTRAP_LOG:?}"
SH
chmod +x "$fake_bin/branch-guard"

BOOTSTRAP_LOG="$tmp/bootstrap.log" \
GIT_BIN="$fake_bin/git" \
MISE_BIN="$fake_bin/mise" \
BRANCH_GUARD_INSTALLER="$fake_bin/branch-guard" \
PATH="/usr/bin:/bin" \
SKIP_WORKTRUNK_HOOKS=true \
SYMPHONY_WORKSPACE_ROOT="$workspace_root" \
SYMPHONY_REPOSITORY_CACHE="$tmp/cache/arrusted.git" \
  "$bootstrap" "$workspace_root/success"

test -f "$workspace_root/success/AGENTS.md"
grep -q '^mise trust \.$' "$tmp/bootstrap.log"
grep -q '^mise install$' "$tmp/bootstrap.log"
grep -Eq '^guard .*/workspaces/success$' "$tmp/bootstrap.log"
grep -q '^git clone --mirror --filter=blob:none ' "$tmp/bootstrap.log"
grep -q '^git clone --filter=blob:none --reference-if-able .*/cache/arrusted.git --dissociate ' \
  "$tmp/bootstrap.log"

rc=0
FAIL_CLONE=1 \
BOOTSTRAP_LOG="$tmp/bootstrap.log" \
GIT_BIN="$fake_bin/git" \
MISE_BIN="$fake_bin/mise" \
BRANCH_GUARD_INSTALLER="$fake_bin/branch-guard" \
PATH="/usr/bin:/bin" \
SKIP_WORKTRUNK_HOOKS=true \
SYMPHONY_WORKSPACE_ROOT="$workspace_root" \
SYMPHONY_REPOSITORY_CACHE="$tmp/cache/arrusted.git" \
  "$bootstrap" "$workspace_root/failure" >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 42 ]]
[[ -z "$(find "$workspace_root/failure" -mindepth 1 -maxdepth 1 -print -quit)" ]]

touch "$workspace_root/nonempty/sentinel"
if BOOTSTRAP_LOG="$tmp/bootstrap.log" \
  GIT_BIN="$fake_bin/git" \
  MISE_BIN="$fake_bin/mise" \
  BRANCH_GUARD_INSTALLER="$fake_bin/branch-guard" \
  PATH="/usr/bin:/bin" \
  SKIP_WORKTRUNK_HOOKS=true \
  SYMPHONY_WORKSPACE_ROOT="$workspace_root" \
  "$bootstrap" "$workspace_root/nonempty" >/dev/null 2>&1; then
  echo "bootstrap accepted a non-empty workspace" >&2
  exit 1
fi
test -f "$workspace_root/nonempty/sentinel"

guard_root="$tmp/guard-workspaces"
mkdir -p "$guard_root/A-241"
git -C "$guard_root/A-241" init -q
SYMPHONY_WORKSPACE_ROOT="$guard_root" "$branch_guard" "$guard_root/A-241"

hook="$guard_root/A-241/.git/hooks/pre-push"
test -x "$hook"

(
  cd "$guard_root/A-241"
  printf 'refs/heads/jason/a-241-parent %040d refs/heads/jason/a-241-parent %040d\n' 1 2 |
    SYMPHONY_WORKSPACE_ROOT="$guard_root" "$hook" origin example.invalid
)

if (
  cd "$guard_root/A-241"
  printf 'refs/heads/jason/a-247-child %040d refs/heads/jason/a-247-child %040d\n' 1 2 |
    SYMPHONY_WORKSPACE_ROOT="$guard_root" "$hook" origin example.invalid
) >/dev/null 2>&1; then
  echo "branch guard accepted another issue's branch" >&2
  exit 1
fi

if (
  cd "$guard_root/A-241"
  printf 'refs/heads/main %040d refs/heads/main %040d\n' 1 2 |
    SYMPHONY_WORKSPACE_ROOT="$guard_root" "$hook" origin example.invalid
) >/dev/null 2>&1; then
  echo "branch guard accepted main" >&2
  exit 1
fi

echo "workspace bootstrap tests passed"
