#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: reconcile-production.sh DESIRED_STATE WORKFLOW_CHECKOUT" >&2
  exit 64
fi

desired="$1"
workflow_checkout="$2"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary="$(mktemp -d)"
port_forward_pid=""
cleanup() {
  [[ -z "$port_forward_pid" ]] || kill "$port_forward_pid" 2>/dev/null || true
  rm -rf "$temporary"
}
trap cleanup EXIT

value() {
  ruby -ryaml -e 'd=YAML.safe_load(File.read(ARGV[0])); keys=ARGV[1].split("."); v=keys.reduce(d){|o,k| o.fetch(k)}; print v' "$desired" "$1"
}

namespace="$(value spec.namespace)"
target="$(value spec.workers.replicas)"
symphony_revision="$(value spec.symphony.revision)"
symphony_upstream_revision="$(value spec.symphony.upstream_revision)"
image_revision="$(value spec.images.built_from_symphony_revision)"
[[ "$image_revision" == "$symphony_revision" ]] || {
  echo "published images do not yet prove the desired Symphony revision" >&2
  exit 1
}

bash "$repo_root/scripts/render-production.sh" "$desired" "$workflow_checkout" "$temporary/production.yaml"

ruby -ryaml -e 'YAML.safe_load(File.read(ARGV[0])).dig("spec","secrets","references").each { |name| puts name }' "$desired" |
  while IFS= read -r secret; do
    kubectl -n "$namespace" get "secret/$secret" >/dev/null
  done

ruby "$repo_root/scripts/extract-resource.rb" \
  "$temporary/production.yaml" ConfigMap symphony-workflow "$temporary/workflow.yaml"
workflow_applied=false
apply_committed() {
  kubectl apply --server-side --force-conflicts --field-manager=symphony-gitops -f "$1"
}

apply_workflow() {
  apply_committed "$temporary/workflow.yaml"
  workflow_applied=true
}

# Server-side apply cannot remove list entries or resources that were created by
# the retired deployment managers. Reconcile their absence explicitly before
# changing capacity so the old autoscaler cannot fight the committed replica
# count and the old reclaimer cannot survive in newly rolled worker pods.
kubectl -n "$namespace" delete deployment symphony-autoscaler --ignore-not-found --wait=true
worker_json="$(kubectl -n "$namespace" get statefulset symphony-worker --ignore-not-found -o json)"
if [[ -n "$worker_json" ]]; then
  reclaimer_patch="$(ruby -rjson -e '
    object=JSON.parse(STDIN.read)
    containers=object.dig("spec", "template", "spec", "containers") || []
    indexes=containers.each_index.select { |index| containers[index]["name"] == "workspace-reclaimer" }
    abort "multiple legacy workspace reclaimers found; refusing cleanup" if indexes.length > 1
    if indexes.one?
      index=indexes.first
      puts JSON.generate([
        {"op" => "test", "path" => "/spec/template/spec/containers/#{index}/name", "value" => "workspace-reclaimer"},
        {"op" => "remove", "path" => "/spec/template/spec/containers/#{index}"}
      ])
    end
  ' <<<"$worker_json")"
  if [[ -n "$reclaimer_patch" ]]; then
    kubectl -n "$namespace" patch statefulset symphony-worker --type=json -p "$reclaimer_patch"
  fi
fi

current="$(kubectl -n "$namespace" get statefulset symphony-worker --ignore-not-found -o jsonpath='{.spec.replicas}')"
current="${current:-0}"

if (( target > current )); then
  ruby "$repo_root/scripts/extract-resource.rb" "$temporary/production.yaml" StatefulSet symphony-worker "$temporary/workers.yaml"
  apply_committed "$temporary/workers.yaml"
  kubectl -n "$namespace" rollout status statefulset/symphony-worker --timeout=30m
  apply_workflow
elif (( target < current )); then
  ruby "$repo_root/scripts/extract-resource.rb" "$temporary/production.yaml" StatefulSet symphony-worker "$temporary/workers-current.yaml" "$current"
  cp "$temporary/production.yaml" "$temporary/reduced-hosts.yaml"
  ruby -ryaml -e '
    path, replicas = ARGV
    docs=YAML.load_stream(File.read(path)).compact
    sts=docs.find { |d| d["kind"]=="StatefulSet" && d.dig("metadata","name")=="symphony-worker" }
    sts["spec"]["replicas"]=Integer(replicas)
    File.write(path, docs.map { |d| YAML.dump(d) }.join("---\n"))
  ' "$temporary/reduced-hosts.yaml" "$current"
  apply_workflow
  apply_committed "$temporary/reduced-hosts.yaml"
  kubectl -n "$namespace" rollout status deployment/symphony-orchestrator --timeout=20m

  kubectl -n "$namespace" port-forward service/symphony-orchestrator 14000:4000 >"$temporary/port-forward.log" 2>&1 &
  port_forward_pid=$!
  for _ in {1..30}; do
    curl --fail --silent http://127.0.0.1:14000/api/v1/state > "$temporary/state.json" && break
    sleep 1
  done
  [[ -s "$temporary/state.json" ]] || { echo "state API unavailable; refusing scale-down" >&2; exit 1; }
  ruby "$repo_root/scripts/validate-scale-down.rb" "$desired" "$current" "$temporary/state.json"
fi

[[ "$workflow_applied" == true ]] || apply_workflow
apply_committed "$temporary/production.yaml"
kubectl -n "$namespace" rollout status statefulset/symphony-worker --timeout=30m
kubectl -n "$namespace" rollout status deployment/symphony-orchestrator --timeout=20m

ready="$(kubectl -n "$namespace" get statefulset symphony-worker -o jsonpath='{.status.readyReplicas}')"
[[ "${ready:-0}" == "$target" ]] || { echo "worker readiness does not match committed replicas" >&2; exit 1; }
actual_replicas="$(kubectl -n "$namespace" get statefulset symphony-worker -o jsonpath='{.spec.replicas}')"
[[ "$actual_replicas" == "$target" ]] || { echo "worker replica count differs from committed desired state" >&2; exit 1; }

expected_orchestrator="$(value spec.images.orchestrator)"
expected_worker="$(value spec.images.worker)"
actual_orchestrator="$(kubectl -n "$namespace" get deployment symphony-orchestrator -o jsonpath='{.spec.template.spec.containers[?(@.name=="orchestrator")].image}')"
actual_worker="$(kubectl -n "$namespace" get statefulset symphony-worker -o jsonpath='{.spec.template.spec.containers[?(@.name=="worker")].image}')"
[[ "$actual_orchestrator" == "$expected_orchestrator" && "$actual_worker" == "$expected_worker" ]] || {
  echo "live images differ from committed desired state" >&2
  exit 1
}

workflow_revision="$(value spec.workflow.revision)"
expected_checksum="$(ruby -ryaml -e '
  document=YAML.load_stream(File.read(ARGV[0])).compact.find { |item| item["kind"]=="ConfigMap" && item.dig("metadata","name")=="symphony-workflow" }
  print document.dig("metadata","annotations","symphony.morganson.me/workflow-sha256")
' "$temporary/production.yaml")"

verify_workload_provenance() {
  local resource="$1"
  kubectl -n "$namespace" get "$resource" -o json | ruby -rjson -e '
    object=JSON.parse(STDIN.read)
    expected_symphony, expected_upstream, expected_workflow, expected_checksum=ARGV
    annotations=object.dig("spec","template","metadata","annotations") || {}
    abort "live Symphony revision provenance differs" unless annotations["symphony.morganson.me/symphony-revision"] == expected_symphony
    abort "live Symphony upstream provenance differs" unless annotations["symphony.morganson.me/symphony-upstream-revision"] == expected_upstream
    abort "live workflow revision provenance differs" unless annotations["symphony.morganson.me/workflow-revision"] == expected_workflow
    abort "live workflow checksum provenance differs" unless annotations["symphony.morganson.me/workflow-sha256"] == expected_checksum
  ' "$symphony_revision" "$symphony_upstream_revision" "$workflow_revision" "$expected_checksum"
}
verify_workload_provenance deployment/symphony-orchestrator
verify_workload_provenance statefulset/symphony-worker

kubectl -n "$namespace" get configmap symphony-workflow -o json | ruby -rjson -rdigest -e '
  config_map=JSON.parse(STDIN.read)
  expected_symphony, expected_upstream, expected_workflow, expected_checksum=ARGV
  annotations=config_map.dig("metadata","annotations") || {}
  metadata=JSON.parse(config_map.dig("data","provenance.json"))
  workflow=config_map.dig("data","WORKFLOW.md")
  abort "live workflow ConfigMap is incomplete" unless workflow
  abort "live workflow content checksum differs" unless Digest::SHA256.hexdigest(workflow) == expected_checksum
  abort "live workflow annotation checksum differs" unless annotations["symphony.morganson.me/workflow-sha256"] == expected_checksum
  abort "live workflow Symphony provenance differs" unless metadata["symphony_revision"] == expected_symphony
  abort "live workflow upstream provenance differs" unless metadata["symphony_upstream_revision"] == expected_upstream
  abort "live workflow repository provenance differs" unless metadata["workflow_revision"] == expected_workflow
' "$symphony_revision" "$symphony_upstream_revision" "$workflow_revision" "$expected_checksum"

echo "production reconciliation verified $target ready workers and exact source/workflow provenance"
