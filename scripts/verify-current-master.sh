#!/usr/bin/env bash
set -euo pipefail

case "${GITHUB_EVENT_NAME:-}" in
  push | workflow_dispatch)
    ;;
  *)
    echo "Refusing production deployment for unsupported event ${GITHUB_EVENT_NAME:-<unset>}" >&2
    exit 1
    ;;
esac

if [[ "${GITHUB_REF:-}" != "refs/heads/master" ]]; then
  echo "Refusing production deployment from non-master ref ${GITHUB_REF:-<unset>}" >&2
  exit 1
fi

for required_name in GITHUB_API_URL GITHUB_REPOSITORY GITHUB_SHA GITHUB_TOKEN; do
  if [[ -z "${!required_name:-}" ]]; then
    echo "Cannot establish deployment freshness: $required_name is unset" >&2
    exit 1
  fi
done

if [[ ! "$GITHUB_SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Cannot establish deployment freshness: GITHUB_SHA is not a full commit SHA" >&2
  exit 1
fi

response_file="$(mktemp)"
trap 'rm -f "$response_file"' EXIT

curl_bin="${CURL_BIN:-curl}"
if ! "$curl_bin" \
  --fail \
  --silent \
  --show-error \
  --location \
  --retry 3 \
  --retry-all-errors \
  --connect-timeout 10 \
  --max-time 30 \
  --header "Accept: application/vnd.github+json" \
  --header "Authorization: Bearer ${GITHUB_TOKEN}" \
  --header "X-GitHub-Api-Version: 2022-11-28" \
  "${GITHUB_API_URL}/repos/${GITHUB_REPOSITORY}/git/ref/heads/master" \
  > "$response_file"; then
  echo "Cannot establish deployment freshness: GitHub master lookup failed" >&2
  exit 1
fi

remote_master_sha="$(
  jq -er '.object.sha | select(type == "string" and test("^[0-9a-f]{40}$"))' \
    "$response_file"
)" || {
  echo "Cannot establish deployment freshness: GitHub returned no valid master SHA" >&2
  exit 1
}

if [[ "$remote_master_sha" != "$GITHUB_SHA" ]]; then
  echo "Skipping stale production deployment: run ${GITHUB_SHA} is not current master ${remote_master_sha}" >&2
  exit 1
fi

echo "Verified ${GITHUB_SHA} is current remote master"
