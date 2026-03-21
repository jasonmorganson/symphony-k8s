#!/usr/bin/env bash
set -euo pipefail

OUT_DIR="${1:-./generated/worker-hostkeys}"
KEY_FILE="$OUT_DIR/ssh_host_ed25519_key"
PUB_FILE="$OUT_DIR/ssh_host_ed25519_key.pub"

mkdir -p "$OUT_DIR"

if [[ -f "$KEY_FILE" || -f "$PUB_FILE" ]]; then
  echo "Refusing to overwrite existing key files in $OUT_DIR" >&2
  exit 1
fi

ssh-keygen -t ed25519 -N "" -f "$KEY_FILE" -C "symphony-worker-host"

echo "Generated:"
echo "  $KEY_FILE"
echo "  $PUB_FILE"
echo

echo "Populate secret 'symphony-worker-hostkeys' with these values:"
echo

echo "ssh_host_ed25519_key: |"
sed 's/^/  /' "$KEY_FILE"
echo
echo "ssh_host_ed25519_key.pub: |"
sed 's/^/  /' "$PUB_FILE"
echo

echo "Alternatively (base64 form):"
echo "  ssh_host_ed25519_key: $(base64 < "$KEY_FILE" | tr -d '\n')"
echo "  ssh_host_ed25519_key.pub: $(base64 < "$PUB_FILE" | tr -d '\n')"
