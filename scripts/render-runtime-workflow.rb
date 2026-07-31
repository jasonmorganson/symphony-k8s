#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "yaml"

abort "usage: render-runtime-workflow.rb DESIRED_STATE WORKFLOW OUTPUT METADATA" unless ARGV.length == 4
desired_path, workflow_path, output_path, metadata_path = ARGV

desired = YAML.safe_load(File.read(desired_path), permitted_classes: [], aliases: false)
spec = desired.fetch("spec")

def assert_keys!(value, allowed, path)
  abort "#{path} must be a mapping" unless value.is_a?(Hash)
  unknown = value.keys - allowed
  abort "unknown or behavioral desired-state keys at #{path}: #{unknown.join(", ")}" unless unknown.empty?
end

assert_keys!(desired, %w[apiVersion kind metadata spec], "root")
assert_keys!(spec, %w[namespace symphony workflow images workers orchestrator server secrets networking], "spec")
assert_keys!(spec.fetch("symphony"), %w[repository revision upstream_repository upstream_revision], "spec.symphony")
assert_keys!(spec.fetch("workflow"), %w[repository path revision], "spec.workflow")
assert_keys!(spec.fetch("images"), %w[built_from_symphony_revision orchestrator worker], "spec.images")
assert_keys!(spec.fetch("workers"), %w[replicas capacity_per_worker workspace_root resources node_selector], "spec.workers")
assert_keys!(spec.fetch("orchestrator"), %w[resources node_selector], "spec.orchestrator")
assert_keys!(spec.fetch("server"), %w[host port], "spec.server")
assert_keys!(spec.fetch("secrets"), %w[references], "spec.secrets")
assert_keys!(spec.fetch("networking"), %w[cloudflare_tunnel_secret], "spec.networking")

workers = spec.fetch("workers")
replicas = Integer(workers.fetch("replicas"))
capacity = Integer(workers.fetch("capacity_per_worker"))
abort "workers.replicas must be between 1 and 100" unless (1..100).cover?(replicas)
abort "capacity_per_worker must be positive" unless capacity.positive?

revision_pattern = /\A[0-9a-f]{40}\z/
symphony_revision = spec.dig("symphony", "revision")
symphony_upstream_revision = spec.dig("symphony", "upstream_revision")
workflow_revision = spec.dig("workflow", "revision")
abort "Symphony revision must be a full commit SHA" unless symphony_revision&.match?(revision_pattern)
abort "Symphony upstream revision must be a full commit SHA" unless symphony_upstream_revision&.match?(revision_pattern)
abort "workflow revision must be a full commit SHA" unless workflow_revision&.match?(revision_pattern)
image_pattern = /\Aghcr\.io\/jasonmorganson\/symphony-k8s-(?:orchestrator|worker)@sha256:[0-9a-f]{64}\z/
%w[orchestrator worker].each do |name|
  abort "#{name} image must be immutable" unless spec.dig("images", name)&.match?(image_pattern)
end
references = spec.dig("secrets", "references")
abort "secret references must be a non-empty unique list" unless references.is_a?(Array) && !references.empty? && references.uniq == references
tunnel_secret = spec.dig("networking", "cloudflare_tunnel_secret")
abort "Cloudflare tunnel secret must be present in secret references" unless references.include?(tunnel_secret)

source = File.binread(workflow_path)
match = source.match(/\A---\n(?<yaml>.*?)\n---\n(?<body>.*)\z/m)
abort "workflow must contain one YAML front matter block" unless match
config = YAML.safe_load(match[:yaml], permitted_classes: [], aliases: false)
original = Marshal.load(Marshal.dump(config))

hosts = replicas.times.map do |ordinal|
  "symphony-worker-#{ordinal}.symphony-worker.#{spec.fetch("namespace")}.svc.cluster.local"
end
config["workspace"] ||= {}
config["workspace"]["root"] = workers.fetch("workspace_root")
config["worker"] ||= {}
config["worker"]["ssh_hosts"] = hosts
config["worker"]["max_concurrent_agents_per_host"] = capacity
config["agent"] ||= {}
config["agent"]["max_concurrent_agents"] = replicas * capacity
config["server"] ||= {}
config["server"]["host"] = spec.dig("server", "host")
config["server"]["port"] = Integer(spec.dig("server", "port"))

def changed_paths(before, after, prefix = [])
  keys = (before.is_a?(Hash) ? before.keys : []) | (after.is_a?(Hash) ? after.keys : [])
  return [prefix.join(".")] if keys.empty? && before != after
  keys.flat_map do |key|
    left = before.is_a?(Hash) ? before[key] : nil
    right = after.is_a?(Hash) ? after[key] : nil
    if left.is_a?(Hash) || right.is_a?(Hash)
      changed_paths(left || {}, right || {}, prefix + [key])
    elsif left != right
      [(prefix + [key]).join(".")]
    else
      []
    end
  end
end

allowed = %w[
  workspace.root
  worker.ssh_hosts
  worker.max_concurrent_agents_per_host
  agent.max_concurrent_agents
  server.host
  server.port
]
changes = changed_paths(original, config)
unknown = changes - allowed
abort "renderer attempted behavioral overrides: #{unknown.join(", ")}" unless unknown.empty?

rendered = "---\n#{YAML.dump(config).delete_prefix("---\n")}---\n#{match[:body]}"
File.binwrite(output_path, rendered)
metadata = {
  "symphony_repository" => spec.dig("symphony", "repository"),
  "symphony_revision" => symphony_revision,
  "symphony_upstream_repository" => spec.dig("symphony", "upstream_repository"),
  "symphony_upstream_revision" => symphony_upstream_revision,
  "workflow_repository" => spec.dig("workflow", "repository"),
  "workflow_revision" => workflow_revision,
  "worker_replicas" => replicas,
  "worker_capacity" => replicas * capacity,
  "workflow_sha256" => Digest::SHA256.hexdigest(rendered)
}
File.write(metadata_path, JSON.pretty_generate(metadata) + "\n")
