#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "yaml"

abort "usage: render-production-manifests.rb DESIRED WORKFLOW METADATA BASE OUTPUT" unless ARGV.length == 5
desired_path, workflow_path, metadata_path, base_path, output_path = ARGV
spec = YAML.safe_load(File.read(desired_path), permitted_classes: [], aliases: false).fetch("spec")
metadata = JSON.parse(File.read(metadata_path))
documents = YAML.load_stream(File.read(base_path)).compact
namespace = spec.fetch("namespace")

documents.each do |document|
  if document["kind"] == "Namespace"
    document["metadata"]["name"] = namespace
  elsif document.dig("metadata", "namespace")
    document["metadata"]["namespace"] = namespace
  end
end

digest_image = /\Aghcr\.io\/jasonmorganson\/symphony-k8s-(?:orchestrator|worker)@sha256:[0-9a-f]{64}\z/
images = spec.fetch("images")
%w[orchestrator worker].each do |name|
  abort "#{name} image must be an immutable project digest" unless images.fetch(name).match?(digest_image)
end

orchestrator = documents.find { |doc| doc["kind"] == "Deployment" && doc.dig("metadata", "name") == "symphony-orchestrator" }
worker = documents.find { |doc| doc["kind"] == "StatefulSet" && doc.dig("metadata", "name") == "symphony-worker" }
cloudflared = documents.find { |doc| doc["kind"] == "Deployment" && doc.dig("metadata", "name") == "cloudflared" }
abort "base manifests are missing Symphony workloads" unless orchestrator && worker
abort "base manifests are missing cloudflared" unless cloudflared
abort "orchestrator must use Recreate" unless orchestrator.dig("spec", "strategy", "type") == "Recreate"

def named_container(workload, name)
  workload.dig("spec", "template", "spec", "containers").find { |container| container["name"] == name }
end

named_container(orchestrator, "orchestrator")["image"] = images.fetch("orchestrator")
named_container(orchestrator, "orchestrator")["resources"] = spec.dig("orchestrator", "resources")
orchestrator.dig("spec", "template", "spec")["nodeSelector"] = spec.dig("orchestrator", "node_selector")
named_container(worker, "worker")["image"] = images.fetch("worker")
named_container(worker, "worker")["resources"] = spec.dig("workers", "resources")
worker["spec"]["replicas"] = Integer(spec.dig("workers", "replicas"))
worker.dig("spec", "template", "spec")["nodeSelector"] = spec.dig("workers", "node_selector")
cloudflared_env = named_container(cloudflared, "cloudflared").fetch("env")
tunnel_token = cloudflared_env.find { |entry| entry["name"] == "TUNNEL_TOKEN" }
abort "cloudflared is missing TUNNEL_TOKEN" unless tunnel_token
tunnel_token.dig("valueFrom", "secretKeyRef")["name"] = spec.dig("networking", "cloudflare_tunnel_secret")

annotations = {
  "symphony.morganson.me/symphony-revision" => spec.dig("symphony", "revision"),
  "symphony.morganson.me/symphony-upstream-revision" => spec.dig("symphony", "upstream_revision"),
  "symphony.morganson.me/workflow-revision" => spec.dig("workflow", "revision"),
  "symphony.morganson.me/workflow-sha256" => metadata.fetch("workflow_sha256")
}
[orchestrator, worker].each do |workload|
  workload["metadata"]["annotations"] = (workload["metadata"]["annotations"] || {}).merge(annotations)
  workload.dig("spec", "template", "metadata")["annotations"] = annotations
end

forbidden = documents.select do |doc|
  doc.dig("metadata", "name")&.match?(/autoscaler|reclaimer/) ||
    doc.dig("spec", "template", "spec", "containers")&.any? { |container| container["name"]&.match?(/autoscaler|reclaimer/) }
end
abort "rendered manifests contain removed scheduling controllers" unless forbidden.empty?

workflow = {
  "apiVersion" => "v1",
  "kind" => "ConfigMap",
  "metadata" => {"name" => "symphony-workflow", "namespace" => namespace, "annotations" => annotations},
  "data" => {"WORKFLOW.md" => File.binread(workflow_path), "provenance.json" => JSON.pretty_generate(metadata) + "\n"}
}
documents << workflow

File.open(output_path, "wb") do |file|
  documents.each_with_index do |doc, index|
    file.write("---\n") unless index.zero?
    file.write(YAML.dump(doc).delete_prefix("---\n"))
  end
end
