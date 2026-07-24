#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT

mkdir -p "$temp_dir/bin" "$temp_dir/fixture" "$temp_dir/install"
printf '%s\n' '#!/usr/bin/env bash' 'echo "v5.8.1"' \
  >"$temp_dir/fixture/kustomize"
chmod +x "$temp_dir/fixture/kustomize"
tar -czf "$temp_dir/fixture/kustomize_v5.8.1_linux_amd64.tar.gz" \
  -C "$temp_dir/fixture" kustomize
checksum="$(
  shasum -a 256 "$temp_dir/fixture/kustomize_v5.8.1_linux_amd64.tar.gz" |
    awk '{ print $1 }'
)"
printf '%s  %s\n' "$checksum" "kustomize_v5.8.1_linux_amd64.tar.gz" \
  >"$temp_dir/fixture/checksums.txt"

cat >"$temp_dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"$CURL_LOG"
output=""
url=""
while (($#)); do
  case "$1" in
    --output)
      output="$2"
      shift 2
      ;;
    http*)
      url="$1"
      shift
      ;;
    *)
      shift
      ;;
  esac
done
cp "$FIXTURE_DIR/${url##*/}" "$output"
EOF
chmod +x "$temp_dir/bin/curl"

PATH="$temp_dir/bin:$PATH" \
  BASH_ENV=/dev/null \
  CURL_LOG="$temp_dir/curl.log" \
  FIXTURE_DIR="$temp_dir/fixture" \
  bash "$repo_root/scripts/install-kustomize.sh" "$temp_dir/install"

test "$("$temp_dir/install/kustomize")" = "v5.8.1"
test "$(wc -l <"$temp_dir/curl.log" | tr -d ' ')" = "2"
while IFS= read -r invocation; do
  grep -Fq -- '--connect-timeout 15' <<<"$invocation"
  grep -Fq -- '--retry 5' <<<"$invocation"
  grep -Fq -- '--retry-all-errors' <<<"$invocation"
  grep -Fq -- '--retry-delay 2' <<<"$invocation"
  grep -Fq -- '--retry-max-time 90' <<<"$invocation"
done <"$temp_dir/curl.log"

echo "Kustomize installer retry tests passed"
