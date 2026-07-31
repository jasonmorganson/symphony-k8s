#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"

abort "usage: update-image-digests.rb DESIRED SYMPHONY_REVISION ORCHESTRATOR WORKER" unless ARGV.length == 4
path, revision, orchestrator, worker = ARGV
sha = /\A[0-9a-f]{40}\z/
digest = /\Aghcr\.io\/jasonmorganson\/symphony-k8s-(?:orchestrator|worker)@sha256:[0-9a-f]{64}\z/
abort "invalid Symphony revision" unless revision.match?(sha)
abort "invalid orchestrator digest" unless orchestrator.match?(digest)
abort "invalid worker digest" unless worker.match?(digest)

contents = File.read(path)
updates = {
  "built_from_symphony_revision" => revision,
  "orchestrator" => orchestrator,
  "worker" => worker
}

updates.each do |key, value|
  pattern = /^    #{Regexp.escape(key)}:\s*.+$/
  abort "expected exactly one #{key} field" unless contents.scan(pattern).length == 1

  contents = contents.sub(pattern) { "    #{key}: #{value}" }
end

document = YAML.safe_load(contents, permitted_classes: [], aliases: false)
images = document.fetch("spec").fetch("images")
updates.each do |key, value|
  abort "failed to update #{key}" unless images.fetch(key) == value
end

File.write(path, contents)
