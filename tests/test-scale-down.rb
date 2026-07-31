#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"
require "yaml"

root = File.expand_path("..", __dir__)
desired = File.join(root, "environments/production/desired-state.yaml")
script = File.join(root, "scripts/validate-scale-down.rb")

Dir.mktmpdir do |dir|
  desired_copy = File.join(dir, "desired-state.yaml")
  desired_data = YAML.safe_load(File.read(desired), permitted_classes: [], aliases: false)
  desired_data["spec"]["namespace"] = "test-symphony"
  File.write(desired_copy, YAML.dump(desired_data))

  state = File.join(dir, "state.json")
  File.write(state, JSON.generate("running" => [], "retrying" => []))
  _out, err, status = Open3.capture3("ruby", script, desired_copy, "12", state)
  abort "idle scale-down should pass: #{err}" unless status.success?

  File.write(state, JSON.generate(
    "running" => [{"issue_identifier" => "A-1", "worker_host" => "symphony-worker-11.symphony-worker.test-symphony.svc.cluster.local"}],
    "retrying" => []
  ))
  _out, _err, status = Open3.capture3("ruby", script, desired_copy, "12", state)
  abort "occupied removed host should fail closed" if status.success?

  File.write(state, JSON.generate("running" => {}, "retrying" => []))
  _out, _err, status = Open3.capture3("ruby", script, desired_copy, "12", state)
  abort "unexpected state API shape should fail closed" if status.success?
end

puts "scale-down state validation is fail closed"
