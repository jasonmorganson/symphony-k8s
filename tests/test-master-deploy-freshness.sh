#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

cat > "$TEMP_DIR/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
if [[ "${CURL_FAIL:-0}" == "1" ]]; then
  exit 22
fi
printf '{"object":{"sha":"%s"}}\n' "${REMOTE_MASTER_SHA:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}"
EOF
chmod +x "$TEMP_DIR/curl"

export CURL_LOG="$TEMP_DIR/curl.log"
export CURL_BIN="$TEMP_DIR/curl"
export GITHUB_API_URL="https://api.github.test"
export GITHUB_REPOSITORY="jasonmorganson/symphony-k8s"
export GITHUB_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
export GITHUB_TOKEN="test-token"
export GITHUB_REF="refs/heads/master"
export GITHUB_EVENT_NAME="push"

bash "$ROOT_DIR/scripts/verify-current-master.sh" > "$TEMP_DIR/success.out"
grep -q "Verified ${GITHUB_SHA} is current remote master" "$TEMP_DIR/success.out"
grep -q '/repos/jasonmorganson/symphony-k8s/git/ref/heads/master' "$CURL_LOG"
if grep -q 'test-token' "$TEMP_DIR/success.out"; then
  echo "freshness verifier must not print its token" >&2
  exit 1
fi

expect_failure="$TEMP_DIR/stale.err"
if REMOTE_MASTER_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
  bash "$ROOT_DIR/scripts/verify-current-master.sh" 2> "$expect_failure"; then
  echo "stale master deployment must fail closed" >&2
  exit 1
fi
grep -q 'Skipping stale production deployment' "$expect_failure"

if CURL_FAIL=1 bash "$ROOT_DIR/scripts/verify-current-master.sh" \
  2> "$TEMP_DIR/unavailable.err"; then
  echo "unavailable GitHub freshness lookup must fail closed" >&2
  exit 1
fi
grep -q 'GitHub master lookup failed' "$TEMP_DIR/unavailable.err"

if GITHUB_EVENT_NAME="schedule" bash "$ROOT_DIR/scripts/verify-current-master.sh" \
  2> "$TEMP_DIR/event.err"; then
  echo "unsupported deployment event must fail closed" >&2
  exit 1
fi
grep -q 'unsupported event schedule' "$TEMP_DIR/event.err"

GITHUB_EVENT_NAME="workflow_dispatch" \
  bash "$ROOT_DIR/scripts/verify-current-master.sh" > "$TEMP_DIR/manual.out"
grep -q "Verified ${GITHUB_SHA} is current remote master" "$TEMP_DIR/manual.out"

if GITHUB_REF="refs/heads/release" bash "$ROOT_DIR/scripts/verify-current-master.sh" \
  2> "$TEMP_DIR/ref.err"; then
  echo "non-master manual deployment must fail closed" >&2
  exit 1
fi
grep -q 'non-master ref refs/heads/release' "$TEMP_DIR/ref.err"

if REMOTE_MASTER_SHA="not-a-sha" bash "$ROOT_DIR/scripts/verify-current-master.sh" \
  2> "$TEMP_DIR/malformed.err"; then
  echo "malformed GitHub freshness response must fail closed" >&2
  exit 1
fi
grep -q 'GitHub returned no valid master SHA' "$TEMP_DIR/malformed.err"

workflow="$ROOT_DIR/.github/workflows/publish-images.yml"
guard_line="$(grep -n 'name: Verify deployment revision is current master' "$workflow" | cut -d: -f1)"
deploy_line="$(grep -n 'name: Deploy immutable images to DOKS' "$workflow" | cut -d: -f1)"
[[ -n "$guard_line" && -n "$deploy_line" && "$guard_line" -lt "$deploy_line" ]]
grep -A3 'name: Verify deployment revision is current master' "$workflow" |
  grep -Fq "GITHUB_TOKEN: \${{ secrets.GITHUB_TOKEN }}"
grep -A2 'group: production-doks' "$workflow" |
  grep -q 'cancel-in-progress: false'

echo "master deployment freshness tests passed"
