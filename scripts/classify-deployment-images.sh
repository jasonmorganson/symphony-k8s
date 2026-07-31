#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLASSIFIER="${IMAGE_INPUT_CLASSIFIER:-$ROOT_DIR/scripts/classify-image-inputs.sh}"
LIVE_SOURCE_REVISION="${1:-}"
TARGET_REVISION="${2:-}"

rebuild_all() {
  "$CLASSIFIER"
}

if [[ ! "$LIVE_SOURCE_REVISION" =~ ^[0-9a-f]{40}$ ]] ||
    [[ ! "$TARGET_REVISION" =~ ^[0-9a-f]{40}$ ]]; then
  rebuild_all
  exit 0
fi

if ! git cat-file -e "${LIVE_SOURCE_REVISION}^{commit}" 2>/dev/null ||
    ! git cat-file -e "${TARGET_REVISION}^{commit}" 2>/dev/null ||
    ! git merge-base --is-ancestor \
      "$LIVE_SOURCE_REVISION" "$TARGET_REVISION"; then
  rebuild_all
  exit 0
fi

changed_file="$(mktemp)"
trap 'rm -f "$changed_file"' EXIT
if ! git diff --name-only \
    "$LIVE_SOURCE_REVISION" "$TARGET_REVISION" > "$changed_file"; then
  rebuild_all
  exit 0
fi
mapfile -t changed_paths < "$changed_file"

# An empty range is ambiguous for a manually repeated deployment. Rebuilding
# all components is the conservative behavior.
"$CLASSIFIER" "${changed_paths[@]}"
