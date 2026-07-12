#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
worker_patch="$ROOT_DIR/k8s/digitalocean/single-node-worker-patch.yaml"
worker_statefulset="$ROOT_DIR/k8s/base/worker-statefulset.yaml"

grep -A5 'requests:' "$worker_patch" | grep -q 'cpu: "2"'
grep -A5 'requests:' "$worker_patch" | grep -q 'memory: 4Gi'
grep -A3 'limits:' "$worker_patch" | grep -q 'cpu: "4"'
grep -A3 'limits:' "$worker_patch" | grep -q 'memory: 6Gi'
grep -A2 'updateStrategy:' "$worker_statefulset" | grep -q 'type: OnDelete'

echo "workflow cost-control tests passed"
