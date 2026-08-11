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

preflight_worker_capacity() {
  local worker_pool cluster
  worker_pool="$(ruby -ryaml -e '
    desired=YAML.safe_load(File.read(ARGV.fetch(0)))
    selector=desired.dig("spec", "workers", "node_selector")
    abort "workers.node_selector must select a DigitalOcean node pool" unless selector.is_a?(Hash)
    pool=selector["doks.digitalocean.com/node-pool"]
    abort "workers.node_selector must set doks.digitalocean.com/node-pool" unless pool.is_a?(String) && !pool.empty?
    print pool
  ' "$desired")"
  cluster="${SYMPHONY_CLUSTER_NAME:-symphony-k8s}"

  doctl kubernetes cluster get "$cluster" -o json | ruby -rjson -e '
    clusters=JSON.parse(STDIN.read)
    cluster=clusters.is_a?(Array) ? clusters.fetch(0) : clusters
    pool_name, target=ARGV
    target=Integer(target)
    pool=(cluster.fetch("node_pools") || []).find { |candidate| candidate["name"] == pool_name }
    abort "worker capacity preflight: node pool #{pool_name.inspect} was not found in cluster #{cluster.fetch("name", "unknown").inspect}" unless pool

    autoscaling=pool.fetch("auto_scale", false)
    configured_nodes=Integer(pool.fetch("count"))
    maximum=autoscaling ? Integer(pool.fetch("max_nodes")) : configured_nodes
    abort "worker capacity preflight: node pool #{pool_name.inspect} has invalid maximum #{maximum}" if maximum < 0

    if target > maximum
      mode=autoscaling ? "autoscaling maximum" : "fixed node count (autoscaling disabled)"
      abort "worker capacity preflight: desired #{target} workers exceeds the #{pool_name} schedulable-node #{mode} of #{maximum}; raise the pool bound or lower spec.workers.replicas"
    end
  ' "$worker_pool" "$target"
}

# Check the selected pool's provider capacity bound before rendering or mutating
# any Kubernetes resource. This fails closed rather than waiting for workers to
# become Pending after a capacity increase.
preflight_worker_capacity

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

wait_for_worker_convergence() {
  local state
  for _ in {1..180}; do
    state="$(kubectl -n "$namespace" get statefulset symphony-worker -o json)"
    if ruby -rjson -e '
      object=JSON.parse(STDIN.read)
      metadata=object.fetch("metadata")
      spec=object.fetch("spec")
      status=object.fetch("status", {})
      target=Integer(ARGV.fetch(0))
      converged = status.fetch("observedGeneration", 0) >= metadata.fetch("generation") &&
        spec.fetch("replicas") == target &&
        status.fetch("replicas", 0) == target &&
        status.fetch("readyReplicas", 0) == target &&
        status.fetch("updatedReplicas", 0) == target &&
        status["currentRevision"] == status["updateRevision"]
      exit(converged ? 0 : 1)
    ' "$target" <<<"$state"; then
      return 0
    fi
    sleep 10
  done
  echo "worker StatefulSet did not converge to committed replicas and revision" >&2
  return 1
}

# Server-side apply cannot remove list entries or resources that were created by
# the retired deployment managers. Reconcile their absence explicitly before
# changing capacity so the old autoscaler cannot fight the committed replica
# count and the old reclaimer cannot survive in newly rolled worker pods.
kubectl -n "$namespace" delete deployment symphony-autoscaler --ignore-not-found --wait=true
worker_json="$(kubectl -n "$namespace" get statefulset symphony-worker --ignore-not-found -o json)"
if [[ -n "$worker_json" ]]; then
  recreate_worker="$(ruby -rjson -e '
    object=JSON.parse(STDIN.read)
    claims=object.dig("spec", "volumeClaimTemplates") || []
    names=claims.map { |claim| claim.dig("metadata", "name") }
    abort "unknown legacy worker volume claims; refusing recreation" unless names.empty? || names == ["workspaces"]
    puts "true" unless names.empty?
  ' <<<"$worker_json")"
  if [[ "$recreate_worker" == true ]]; then
    kubectl -n "$namespace" delete statefulset symphony-worker --cascade=orphan --wait=true
    worker_json=""
  fi
fi
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
  permissions_patch="$(ruby -rjson -e '
    object=JSON.parse(STDIN.read)
    containers=object.dig("spec", "template", "spec", "initContainers") || []
    indexes=containers.each_index.select { |index| containers[index]["name"] == "init-workspace-permissions" }
    abort "multiple legacy workspace permission initializers found; refusing cleanup" if indexes.length > 1
    if indexes.one?
      index=indexes.first
      puts JSON.generate([
        {"op" => "test", "path" => "/spec/template/spec/initContainers/#{index}/name", "value" => "init-workspace-permissions"},
        {"op" => "remove", "path" => "/spec/template/spec/initContainers/#{index}"}
      ])
    end
  ' <<<"$worker_json")"
  if [[ -n "$permissions_patch" ]]; then
    kubectl -n "$namespace" patch statefulset symphony-worker --type=json -p "$permissions_patch"
  fi
fi

# Server-side apply cannot remove a mutually exclusive probe handler that was
# previously owned in the live Deployment. Remove the retired exec handler
# before applying the health endpoint probe, or Kubernetes rejects the update
# as an invalid multi-handler liveness probe.
orchestrator_json="$(kubectl -n "$namespace" get deployment symphony-orchestrator -o json)"
orchestrator_probe_patch="$(ruby -rjson -e '
  object=JSON.parse(STDIN.read)
  containers=object.dig("spec", "template", "spec", "containers") || []
  indexes=containers.each_index.select { |index| containers[index]["name"] == "orchestrator" }
  abort "expected one orchestrator container" unless indexes.one?
  index=indexes.first
  probe=containers[index]["livenessProbe"] || {}
  if probe.key?("exec")
    puts JSON.generate([
      {"op" => "test", "path" => "/spec/template/spec/containers/#{index}/name", "value" => "orchestrator"},
      {"op" => "add", "path" => "/spec/template/spec/containers/#{index}/livenessProbe/httpGet", "value" => {"path" => "/healthz", "port" => "http"}},
      {"op" => "remove", "path" => "/spec/template/spec/containers/#{index}/livenessProbe/exec"}
    ])
  end
' <<<"$orchestrator_json")"
if [[ -n "$orchestrator_probe_patch" ]]; then
  kubectl -n "$namespace" patch deployment symphony-orchestrator --type=json -p "$orchestrator_probe_patch"
fi

current="$(kubectl -n "$namespace" get statefulset symphony-worker --ignore-not-found -o jsonpath='{.spec.replicas}')"
current="${current:-0}"

if (( target > current )); then
  ruby "$repo_root/scripts/extract-resource.rb" "$temporary/production.yaml" StatefulSet symphony-worker "$temporary/workers.yaml"
  apply_committed "$temporary/workers.yaml"
  kubectl -n "$namespace" rollout status statefulset/symphony-worker --timeout=30m
  wait_for_worker_convergence
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
  kubectl -n "$namespace" rollout status deployment/symphony-orchestrator --timeout=40m

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
wait_for_worker_convergence
kubectl -n "$namespace" rollout status deployment/symphony-orchestrator --timeout=40m

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
  local workflow_location="$2"
  kubectl -n "$namespace" get "$resource" -o json | ruby -rjson -e '
    object=JSON.parse(STDIN.read)
    expected_symphony, expected_upstream, expected_workflow, expected_checksum, workflow_location=ARGV
    template_annotations=object.dig("spec","template","metadata","annotations") || {}
    abort "live Symphony revision provenance differs" unless template_annotations["symphony.morganson.me/symphony-revision"] == expected_symphony
    abort "live Symphony upstream provenance differs" unless template_annotations["symphony.morganson.me/symphony-upstream-revision"] == expected_upstream
    workflow_annotations = if workflow_location == "template"
      template_annotations
    else
      object.dig("metadata","annotations") || {}
    end
    abort "live workflow revision provenance differs" unless workflow_annotations["symphony.morganson.me/workflow-revision"] == expected_workflow
    abort "live workflow checksum provenance differs" unless workflow_annotations["symphony.morganson.me/workflow-sha256"] == expected_checksum
  ' "$symphony_revision" "$symphony_upstream_revision" "$workflow_revision" "$expected_checksum" "$workflow_location"
}
verify_workload_provenance deployment/symphony-orchestrator template
verify_workload_provenance statefulset/symphony-worker metadata

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
