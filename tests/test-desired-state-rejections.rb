#!/usr/bin/env ruby
# frozen_string_literal: true

require "open3"
require "tmpdir"
require "yaml"

root = File.expand_path("..", __dir__)
canonical = YAML.safe_load(File.read(File.join(root, "environments/production/desired-state.yaml")))
workflow = File.join(root, "tests/fixtures-workflow.md")
fixture = "---\ntracker:\n  kind: linear\n---\npolicy body\n"

def rejected?(root, desired, workflow)
  Dir.mktmpdir do |dir|
    path = File.join(dir, "desired.yaml")
    source = File.join(dir, "WORKFLOW.md")
    File.write(path, YAML.dump(desired))
    File.write(source, workflow)
    _out, _err, status = Open3.capture3(
      "ruby", File.join(root, "scripts/render-runtime-workflow.rb"),
      path, source, File.join(dir, "out"), File.join(dir, "metadata")
    )
    !status.success?
  end
end

overlay = Marshal.load(Marshal.dump(canonical))
overlay["spec"]["workflow"]["overlay"] = "behavioral prose"
abort "behavioral overlay was accepted" unless rejected?(root, overlay, fixture)

mutable = Marshal.load(Marshal.dump(canonical))
mutable["spec"]["images"]["worker"] = "ghcr.io/jasonmorganson/symphony-k8s-worker:latest"
abort "mutable image tag was accepted" unless rejected?(root, mutable, fixture)

short_upstream = Marshal.load(Marshal.dump(canonical))
short_upstream["spec"]["symphony"]["upstream_revision"] = "main"
abort "mutable upstream pin was accepted" unless rejected?(root, short_upstream, fixture)

missing_secrets = Marshal.load(Marshal.dump(canonical))
missing_secrets["spec"]["secrets"]["references"] = []
abort "missing secret references were accepted" unless rejected?(root, missing_secrets, fixture)

insufficient_pool = Marshal.load(Marshal.dump(canonical))
insufficient_pool["spec"]["workers"]["node_pool"]["max_nodes"] = 6
abort "insufficient worker-pool maximum was accepted" unless rejected?(root, insufficient_pool, fixture)

puts "unsafe desired-state inputs are rejected"
