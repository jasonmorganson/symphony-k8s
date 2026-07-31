#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKERFILE="$ROOT_DIR/docker/worker/Dockerfile"

required_packages=(gh jq ripgrep unzip zip)
for package in "${required_packages[@]}"; do
  grep -q "^    ${package} \\\\$" "$DOCKERFILE"
done

grep -q 'gh --version' "$DOCKERFILE"
grep -q 'jq --version' "$DOCKERFILE"
grep -q 'rg --version' "$DOCKERFILE"
grep -q 'unzip -v' "$DOCKERFILE"
grep -q 'zip --version' "$DOCKERFILE"

if [[ $# -eq 0 ]]; then
  exit 0
fi

if [[ $# -ne 1 ]]; then
  echo "usage: $0 [worker-image]" >&2
  exit 2
fi

docker run --rm --entrypoint sh "$1" -c '
  set -eu
  command -v gh
  command -v jq
  command -v rg
  command -v unzip
  command -v zip
  gh --version
  jq --version
  rg --version
  unzip -v
  zip --version
'
