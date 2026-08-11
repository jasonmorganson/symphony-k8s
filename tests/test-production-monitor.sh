#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/bin"

cat >"$tmpdir/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case " $* " in
  *' get deployment/symphony-orchestrator -o json '*)
    printf '%s\n' '{"metadata":{"generation":4},"spec":{"replicas":1},"status":{"observedGeneration":4,"readyReplicas":1,"availableReplicas":1}}'
    ;;
  *' get statefulset/symphony-worker -o json '*)
    printf '%s\n' '{"metadata":{"generation":7},"spec":{"replicas":2},"status":{"observedGeneration":7,"readyReplicas":2,"updatedReplicas":2,"currentRevision":"worker-7","updateRevision":"worker-7"}}'
    ;;
  *' get endpoints/symphony-orchestrator -o json '*)
    printf '%s\n' '{"subsets":[{"addresses":[{"ip":"10.0.0.9"}]}]}'
    ;;
  *' port-forward service/symphony-orchestrator '*)
    while :; do sleep 1; done
    ;;
  *)
    echo "unexpected kubectl invocation: $*" >&2
    exit 1
    ;;
esac
EOF
cat >"$tmpdir/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"sessions":[]}'
EOF
chmod +x "$tmpdir/bin/kubectl" "$tmpdir/bin/curl"

PATH="$tmpdir/bin:$PATH" BASH_ENV=/dev/null SYMPHONY_MONITOR_PORT=14019 \
  bash "$ROOT_DIR/scripts/monitor-production.sh" >"$tmpdir/output"
grep -q 'production monitor verified workload convergence, service endpoints, and state API' "$tmpdir/output"

sed 's/"addresses":\[{"ip":"10.0.0.9"}\]/"addresses":[]/' "$tmpdir/bin/kubectl" >"$tmpdir/bin/kubectl-no-endpoint"
chmod +x "$tmpdir/bin/kubectl-no-endpoint"
mv "$tmpdir/bin/kubectl" "$tmpdir/bin/kubectl-ready"
mv "$tmpdir/bin/kubectl-no-endpoint" "$tmpdir/bin/kubectl"
if PATH="$tmpdir/bin:$PATH" BASH_ENV=/dev/null SYMPHONY_MONITOR_PORT=14019 \
  bash "$ROOT_DIR/scripts/monitor-production.sh" >"$tmpdir/no-endpoint-output" 2>&1; then
  echo "production monitor accepted an endpoint-free service" >&2
  exit 1
fi
grep -q 'orchestrator service has no ready endpoints' "$tmpdir/no-endpoint-output"

echo "production monitor is fail closed"
