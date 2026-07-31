#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
desired="$repo_root/environments/production/desired-state.yaml"
workflow_checkout="${ARRUSTED_WORKFLOW_CHECKOUT:-/Volumes/Home/jasonmorganson/.config/codex/worktrees/rebuild-arrusted-workflow}"
output="$(mktemp)"
stale_desired="$(mktemp)"
trap 'rm -f "$output" "$stale_desired"' EXIT

bash "$repo_root/scripts/render-production.sh" "$desired" "$workflow_checkout" "$output"
ruby -ryaml -e '
  docs=YAML.load_stream(File.read(ARGV[0])).compact
  sts=docs.find { |d| d["kind"] == "StatefulSet" && d.dig("metadata","name") == "symphony-worker" }
  cm=docs.find { |d| d["kind"] == "ConfigMap" && d.dig("metadata","name") == "symphony-workflow" }
  cloudflared=docs.find { |d| d["kind"] == "Deployment" && d.dig("metadata","name") == "cloudflared" }
  desired=YAML.safe_load(File.read(ARGV[1]))
  replicas=desired.dig("spec","workers","replicas")
  namespace=desired.dig("spec","namespace")
  abort "replica drift" unless sts.dig("spec","replicas") == replicas
  abort "namespace drift" unless docs.all? { |d| d["kind"] == "Namespace" ? d.dig("metadata","name") == namespace : !d.dig("metadata","namespace") || d.dig("metadata","namespace") == namespace }
  front=YAML.safe_load(cm.dig("data","WORKFLOW.md").split("---\n",3)[1])
  abort "host drift" unless front.dig("worker","ssh_hosts").length == replicas
  abort "capacity drift" unless front.dig("agent","max_concurrent_agents") == replicas
  tunnel=cloudflared.dig("spec","template","spec","containers").find { |c| c["name"] == "cloudflared" }.fetch("env").find { |e| e["name"] == "TUNNEL_TOKEN" }
  abort "networking secret drift" unless tunnel.dig("valueFrom","secretKeyRef","name") == desired.dig("spec","networking","cloudflare_tunnel_secret")
  abort "fork provenance drift" unless cm.dig("metadata","annotations","symphony.morganson.me/symphony-revision") == desired.dig("spec","symphony","revision")
  abort "upstream provenance drift" unless cm.dig("metadata","annotations","symphony.morganson.me/symphony-upstream-revision") == desired.dig("spec","symphony","upstream_revision")
' "$output" "$desired"

if grep -Eq 'autoscaler|workspace-reclaimer|workflow-throughput-overlay|drain_state_path|affinity_state_path' "$output"; then
  echo "removed scheduling policy leaked into production manifests" >&2
  exit 1
fi

ruby -ryaml -e '
  desired=YAML.safe_load(File.read(ARGV[0]))
  desired["spec"]["workflow"]["revision"]="0000000000000000000000000000000000000000"
  File.write(ARGV[1], YAML.dump(desired))
' "$desired" "$stale_desired"
if bash "$repo_root/scripts/render-production.sh" "$stale_desired" "$workflow_checkout" "$output" >/dev/null 2>&1; then
  echo "stale workflow pin was accepted" >&2
  exit 1
fi

echo "production manifest render is consistent"
