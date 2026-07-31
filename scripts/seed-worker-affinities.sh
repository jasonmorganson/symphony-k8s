#!/usr/bin/env bash
set -euo pipefail

KUBECTL="${KUBECTL:-kubectl}"
JQ="${JQ:-jq}"
STATE_PATH="${SYMPHONY_STATE_PATH:-/api/v1/namespaces/symphony/services/http:symphony-orchestrator:4000/proxy/api/v1/state}"
seed_file="${1:?usage: seed-worker-affinities.sh SEED_FILE}"

[[ -f "$seed_file" ]] || {
  echo "worker affinity seed file does not exist: $seed_file" >&2
  exit 1
}

state="$("$KUBECTL" get --raw "$STATE_PATH")"
configured_hosts="$(
  printf '%s' "$state" | "$JQ" -ce '
    .worker_pool.configured_hosts |
    if type == "array" and length == (unique | length) and
      all(.[]; type == "string" and length > 0)
    then . else error("invalid configured worker hosts") end
  '
)"

seed="$(
  "$JQ" -ce --argjson configured "$configured_hosts" '
    if .version == 1 and (.affinities | type) == "object" and
      ([.affinities | to_entries[] |
        (.key | type == "string" and length > 0) and
        (.value as $host |
          ($host | type == "string") and ($configured | index($host)) != null)] | all)
    then . else error("invalid worker affinity seed") end
  ' "$seed_file"
)"

printf '%s' "$seed" | "$KUBECTL" -n symphony exec \
  deployment/symphony-orchestrator -c orchestrator -i -- sh -ceu '
    path=/srv/symphony/workspaces/.worker-affinities.json
    temporary="${path}.tmp"
    test ! -e "$path"
    umask 077
    cat > "$temporary"
    sync "$temporary"
    mv "$temporary" "$path"
  '

echo "Seeded durable Symphony worker affinities without overwriting existing state"
