#!/usr/bin/env bash
set -euo pipefail

VERSION="${KUSTOMIZE_VERSION:-5.8.1}"
INSTALL_DIR="${1:-${HOME}/.local/bin}"
OS="${KUSTOMIZE_OS:-linux}"
ARCH="${KUSTOMIZE_ARCH:-amd64}"
ASSET="kustomize_v${VERSION}_${OS}_${ARCH}.tar.gz"
RELEASE_URL="https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${VERSION}"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

download() {
  local url="$1"
  local output="$2"

  curl --fail --silent --show-error --location \
    --connect-timeout 15 \
    --retry 5 \
    --retry-all-errors \
    --retry-delay 2 \
    --retry-max-time 90 \
    "$url" \
    --output "$output"
}

download "$RELEASE_URL/$ASSET" "$TEMP_DIR/$ASSET"
download "$RELEASE_URL/checksums.txt" "$TEMP_DIR/checksums.txt"

expected_checksum="$(awk -v asset="$ASSET" '$2 == asset { print $1 }' "$TEMP_DIR/checksums.txt")"
if [[ ! "$expected_checksum" =~ ^[0-9a-f]{64}$ ]]; then
  echo "missing checksum for $ASSET" >&2
  exit 1
fi
actual_checksum="$(shasum -a 256 "$TEMP_DIR/$ASSET" | awk '{ print $1 }')"
if [[ "$actual_checksum" != "$expected_checksum" ]]; then
  echo "checksum mismatch for $ASSET" >&2
  exit 1
fi

tar -xzf "$TEMP_DIR/$ASSET" -C "$TEMP_DIR"
mkdir -p "$INSTALL_DIR"
install -m 0755 "$TEMP_DIR/kustomize" "$INSTALL_DIR/kustomize"
"$INSTALL_DIR/kustomize" version
