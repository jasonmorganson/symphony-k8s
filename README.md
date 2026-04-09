# Symphony Kubernetes (Skaffold) Scaffold

This repository provides a ready-to-run Kubernetes scaffold for running OpenAI Symphony with SSH-connected workers.

## Architecture

- `symphony-orchestrator` runs as a single central Deployment.
- `symphony-worker` runs as a StatefulSet with stable pod identities and per-pod storage.
- Orchestrator reaches workers over SSH stdio and launches `codex app-server` remotely.
- Workflow config (`WORKFLOW.md`) is delivered via ConfigMap and mounted into the orchestrator.

## Why StatefulSet For Workers

Workers need continuity for:

- stable DNS names for `worker.ssh_hosts`
- stable SSH host identity (known_hosts trust)
- durable per-worker workspace state

A Deployment does not guarantee stable pod identity or volume continuity, while StatefulSet does.

## Directory Layout

- `docker/` image definitions and SSH runtime config
- `k8s/base/` Kubernetes manifests
- `scripts/` helper scripts for SSH key material

## Setup

### Automated local bootstrap (recommended)

1. Export required configuration:

```bash
export LINEAR_API_KEY="lin_xxx"
export OPENAI_API_KEY="sk-xxx"
export LINEAR_PROJECT_SLUG="your-linear-project-slug"
export REPO_URL="https://github.com/your-org/your-repo.git"
```

2. Run bootstrap:

```bash
scripts/bootstrap-local.sh
```

What bootstrap does automatically:

- creates/reuses SSH keys under `generated/ssh/`
- creates/updates all required secrets:
  - `symphony-secrets`
  - `symphony-orchestrator-ssh`
  - `symphony-worker-authorized-keys`
  - `symphony-worker-hostkeys`
- renders and applies `symphony-workflow` ConfigMap with your `LINEAR_PROJECT_SLUG` and `REPO_URL`
- reapplies the generated workflow after Skaffold so the live cluster does not keep the placeholder repo manifest
- runs `skaffold run -p dev`
- performs an orchestrator -> worker SSH smoke test

Optional flags:

```bash
scripts/bootstrap-local.sh --profile prod --namespace symphony
scripts/bootstrap-local.sh --skip-skaffold
```

### Manual setup (minimum required)

You still need to provide environment-specific values:

- valid `LINEAR_API_KEY`
- valid `OPENAI_API_KEY`
- correct `LINEAR_PROJECT_SLUG`
- target repository URL (`REPO_URL`)

Additional commands:

Start dev loop:

```bash
skaffold dev
```

One-shot prod-style deploy:

```bash
skaffold run -p prod
```

Render manifests only:

```bash
skaffold render > rendered.yaml
```

Access the orchestrator UI/API from your host:

```text
http://127.0.0.1:4000
```

For remote clusters, use the `symphony-orchestrator-public` `LoadBalancer` service on port `80`. In clusters without a provisioned external IP, port-forward the internal `ClusterIP` service:

```bash
kubectl -n symphony port-forward svc/symphony-orchestrator 4000:4000
```

On OrbStack, the `LoadBalancer` object may show an external IP but still not be reachable from the host. In that environment, `port-forward` is the reliable access path.

## Required Secrets

- `symphony-secrets`
  - `LINEAR_API_KEY`
  - `OPENAI_API_KEY`
- `symphony-orchestrator-ssh`
  - `id_ed25519`
  - `known_hosts`
  - `config`
- `symphony-worker-authorized-keys`
  - `authorized_keys`
- `symphony-worker-hostkeys`
  - `ssh_host_ed25519_key`
  - `ssh_host_ed25519_key.pub`

## Caveats

- Stable SSH host keys are required. Do not rotate worker host keys without updating orchestrator `known_hosts`.
- Workers need persistent volumes for reliable continuation turns.
- Avoid a shared RWX workspace volume by default; use per-worker PVCs.
- This is an engineering-preview style setup and should be hardened before production use (RBAC, PodSecurity, image provenance, secret management, backup, and monitoring).
