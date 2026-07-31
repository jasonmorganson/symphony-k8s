#!/usr/bin/env bash
set -euo pipefail

name="${1:-image}"
image="${2:-}"
repository="${3:-}"
DOCKER="${DOCKER:-docker}"

if [[ -z "$repository" ]] ||
    [[ ! "$image" =~ ^${repository}@sha256:[0-9a-f]{64}$ ]]; then
  echo "$name must be an immutable $repository digest" >&2
  exit 1
fi

expected_digest="${image##*@}"
resolved_digest="$("$DOCKER" buildx imagetools inspect \
  "$image" --format '{{.Manifest.Digest}}')"
if [[ "$resolved_digest" != "$expected_digest" ]]; then
  echo "$name resolved to an unexpected manifest digest" >&2
  exit 1
fi

echo "$image"
