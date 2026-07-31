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

document = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
images = document.fetch("spec").fetch("images")
images["built_from_symphony_revision"] = revision
images["orchestrator"] = orchestrator
images["worker"] = worker
File.write(path, YAML.dump(document))
