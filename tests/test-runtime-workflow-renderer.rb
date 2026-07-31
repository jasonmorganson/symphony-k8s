#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"
require "yaml"

root = File.expand_path("..", __dir__)
desired = File.join(root, "environments/production/desired-state.yaml")
fixture = <<~WORKFLOW
  ---
  tracker:
    kind: linear
    active_states: [Todo, In Progress, Merging]
  polling:
    interval_ms: 300000
  workspace:
    root: local
  hooks:
    after_create: |
      printf 'keep me byte exact\\n'
  agent:
    max_concurrent_agents: 1
  ---
  # Policy body

  This body is behavior and must remain byte-for-byte.  
WORKFLOW

Dir.mktmpdir do |dir|
  source = File.join(dir, "WORKFLOW.md")
  output = File.join(dir, "rendered.md")
  metadata = File.join(dir, "metadata.json")
  File.binwrite(source, fixture)
  command = ["ruby", File.join(root, "scripts/render-runtime-workflow.rb"), desired, source, output, metadata]
  stdout, stderr, status = Open3.capture3(*command)
  abort "renderer failed: #{stdout}#{stderr}" unless status.success?

  rendered = File.binread(output)
  source_body = fixture.split("---\n", 3).last
  rendered_body = rendered.split("---\n", 3).last
  abort "workflow body changed" unless rendered_body == source_body

  front = YAML.safe_load(rendered.split("---\n", 3)[1], permitted_classes: [], aliases: false)
  replicas = YAML.safe_load(File.read(desired)).dig("spec", "workers", "replicas")
  abort "host count differs from replicas" unless front.dig("worker", "ssh_hosts").length == replicas
  abort "global capacity differs from replicas" unless front.dig("agent", "max_concurrent_agents") == replicas
  abort "behavioral front matter changed" unless front.dig("tracker", "active_states") == ["Todo", "In Progress", "Merging"]
  provenance = JSON.parse(File.read(metadata))
  desired_data = YAML.safe_load(File.read(desired))
  abort "metadata missing checksum" unless provenance.fetch("workflow_sha256").length == 64
  abort "fork provenance drift" unless provenance.fetch("symphony_revision") == desired_data.dig("spec", "symphony", "revision")
  abort "upstream provenance drift" unless provenance.fetch("symphony_upstream_revision") == desired_data.dig("spec", "symphony", "upstream_revision")
end

puts "runtime workflow renderer contract is valid"
