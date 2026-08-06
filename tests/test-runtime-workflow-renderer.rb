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

  A failure affecting the current issue's implementation, acceptance criteria,
  attached PR, merge, required checks, or post-merge validation belongs to the
  current issue; do not create a related, blocking, or replacement Linear issue.

  Before creating a clearly unrelated Backlog follow-up, record an Unrelated
  follow-up rationale in the current issue workpad.

  Keep the issue in Merging through post-merge checks. Attach a repair PR to the
  same issue and move to Done only after the final merged evidence is green.
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
  abort "implementation failure ownership rule missing" unless rendered_body.include?("belongs to the\ncurrent issue; do not create a related, blocking, or replacement Linear issue.")
  abort "unrelated follow-up rationale rule missing" unless rendered_body.include?("Before creating a clearly unrelated Backlog follow-up, record an Unrelated\nfollow-up rationale in the current issue workpad.")
  abort "same-issue post-merge repair rule missing" unless rendered_body.include?("Keep the issue in Merging through post-merge checks. Attach a repair PR to the\nsame issue and move to Done only after the final merged evidence is green.")

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
