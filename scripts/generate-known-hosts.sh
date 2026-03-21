#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -eq 0 ]]; then
  set -- \
    symphony-worker-0.symphony-worker.symphony.svc.cluster.local \
    symphony-worker-1.symphony-worker.symphony.svc.cluster.local \
    symphony-worker-2.symphony-worker.symphony.svc.cluster.local
fi

for host in "$@"; do
  ssh-keyscan -T 5 -t ed25519 "$host" 2>/dev/null
done
