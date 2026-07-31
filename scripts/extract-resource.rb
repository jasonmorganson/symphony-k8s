#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"

abort "usage: extract-resource.rb MANIFEST KIND NAME OUTPUT [REPLICAS]" unless (4..5).cover?(ARGV.length)
manifest, kind, name, output, replicas = ARGV
document = YAML.load_stream(File.read(manifest)).compact.find do |item|
  item["kind"] == kind && item.dig("metadata", "name") == name
end
abort "resource not found: #{kind}/#{name}" unless document
document["spec"]["replicas"] = Integer(replicas) if replicas
File.write(output, YAML.dump(document))
