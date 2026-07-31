#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "yaml"

abort "usage: validate-scale-down.rb DESIRED_STATE CURRENT_REPLICAS STATE_JSON" unless ARGV.length == 3
desired = YAML.safe_load(File.read(ARGV[0]), permitted_classes: [], aliases: false)
target = Integer(desired.dig("spec", "workers", "replicas"))
current = Integer(ARGV[1])
exit 0 if target >= current

state = JSON.parse(File.read(ARGV[2]))
running = state.fetch("running")
retrying = state.fetch("retrying")
abort "state API running/retrying must be arrays" unless running.is_a?(Array) && retrying.is_a?(Array)

namespace = desired.dig("spec", "namespace")
removed = (target...current).map { |i| "symphony-worker-#{i}.symphony-worker.#{namespace}.svc.cluster.local" }
occupied = (running + retrying).each_with_object([]) do |session, result|
  abort "state API sessions must be objects" unless session.is_a?(Hash)
  host = session["worker_host"] || session["workerHost"]
  result << host if removed.include?(host)
end
abort "removed workers still own running or retrying sessions: #{occupied.uniq.join(", ")}" unless occupied.empty?

puts "scale-down plan is safe for removed hosts: #{removed.join(", ")}"
