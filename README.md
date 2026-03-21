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

1. Quick smoke test with placeholders (not for real runs):

```bash
kubectl apply -f k8s/base/secrets.example.yaml
```

2. Recommended: copy and edit secrets:

```bash
cp k8s/base/secrets.example.yaml k8s/base/secrets.yaml
# Edit placeholders in k8s/base/secrets.yaml
```

3. Apply edited secrets:

```bash
kubectl apply -f k8s/base/secrets.yaml
```

4. Start dev loop:

```bash
skaffold dev
```

5. One-shot prod-style deploy:

```bash
skaffold run -p prod
```

6. Render manifests only:

```bash
skaffold render > rendered.yaml
```

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
