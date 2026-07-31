group "default" {
  targets = [
    "runtime-base",
    "release",
    "orchestrator",
    "worker",
  ]
}

target "runtime-base" {
  context    = "."
  dockerfile = "docker/runtime-base/Dockerfile"
  cache-from = ["type=gha,scope=symphony-runtime-base"]
}

target "release" {
  context    = "."
  dockerfile = "docker/release/Dockerfile"
  cache-from = ["type=gha,scope=symphony-release"]
}

target "orchestrator" {
  context    = "."
  dockerfile = "docker/orchestrator/Dockerfile"
  contexts = {
    runtime-base = "target:runtime-base"
    release      = "target:release"
  }
  args = {
    RUNTIME_BASE           = "runtime-base"
    SYMPHONY_RELEASE_IMAGE = "release"
  }
  cache-from = ["type=gha,scope=symphony-orchestrator"]
}

target "worker" {
  context    = "."
  dockerfile = "docker/worker/Dockerfile"
  contexts = {
    runtime-base = "target:runtime-base"
  }
  args = {
    RUNTIME_BASE = "runtime-base"
  }
  cache-from = ["type=gha,scope=symphony-worker"]
}
