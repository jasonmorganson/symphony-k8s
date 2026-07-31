#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="$ROOT_DIR/.github/workflows/publish-images.yml"

concurrency_block="$(
  sed -n '/^concurrency:$/,/^jobs:$/p' "$workflow" | sed '$d'
)"

grep -Fqx 'concurrency:' <<<"$concurrency_block"
# GitHub expressions are intentionally matched as literal workflow text.
# shellcheck disable=SC2016
grep -Fqx \
  "  group: \${{ github.event_name == 'pull_request' && format('publish-images-pr-{0}', github.event.pull_request.number) || 'production-doks' }}" \
  <<<"$concurrency_block"
grep -Fqx \
  "  cancel-in-progress: \${{ github.event_name == 'pull_request' }}" \
  <<<"$concurrency_block"

[[ "$(grep -Fc 'cancel-in-progress:' <<<"$concurrency_block")" -eq 1 ]]
[[ "$(grep -Fc 'publish-images-pr-{0}' <<<"$concurrency_block")" -eq 1 ]]
[[ "$(grep -Fc 'production-doks' <<<"$concurrency_block")" -eq 1 ]]

echo "publish workflow concurrency tests passed"
