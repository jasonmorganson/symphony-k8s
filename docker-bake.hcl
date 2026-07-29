group "default" {
  targets = [
    "runtime-base",
    "release",
    "orchestrator",
    "worker",
    "autoscaler",
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

target "control-plane-build" {
  context    = "."
  dockerfile = "docker/control-plane/Dockerfile"
  cache-from = ["type=gha,scope=symphony-control-plane-build"]
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
    runtime-base        = "target:runtime-base"
    control-plane-build = "target:control-plane-build"
  }
  args = {
    RUNTIME_BASE        = "runtime-base"
    CONTROL_PLANE_BUILD = "control-plane-build"
  }
  cache-from = ["type=gha,scope=symphony-worker"]
}

target "autoscaler" {
  context    = "."
  dockerfile = "docker/autoscaler/Dockerfile"
  contexts = {
    control-plane-build = "target:control-plane-build"
  }
  args = {
    CONTROL_PLANE_BUILD = "control-plane-build"
  }
  cache-from = ["type=gha,scope=symphony-autoscaler"]
}
