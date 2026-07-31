# Symphony Kubernetes

This repository is the infrastructure owner for the Symphony deployment. It
packages an upstream-equivalent `jasonmorganson/symphony` revision, renders the
repository-owned Arrusted workflow, and reconciles Kubernetes from reviewed
Git state. It contains no task routing, merge policy, Linear state policy,
autoscaler, workspace reclaimer, worker-affinity registry, or prompt overlay.

## Ownership boundaries

- `jasonmorganson/symphony` supplies the generic scheduler and existing state
  API. `scripts/verify-symphony-upstream.sh` proves its pinned tree is exactly
  the pinned upstream tree before packaging.
- `withAutograph/arrusted-development/WORKFLOW.md` supplies all behavioral
  policy, setup hooks, state routing, review gates, merge authorization, and
  exact-main reconciliation.
- This repository supplies images, SSH worker infrastructure, immutable
  desired state, structural workflow projection, diagnostics, and GitOps
  reconciliation.

## Committed desired state

[`environments/production/desired-state.yaml`](environments/production/desired-state.yaml)
is the only production input. It pins:

- exact Symphony fork, pinned upstream, and Arrusted revisions;
- immutable orchestrator and worker image digests and their Symphony build
  provenance;
- worker replica count and per-worker capacity;
- resource requests and limits;
- node placement, namespace, networking, and Secret references.

The current digest values are the last live immutable images. The first image
publication after this redesign opens a reviewed PR that changes the digest
pins and `built_from_symphony_revision` together. Reconciliation fails closed
until that provenance equals the desired Symphony revision, so an old image is
never represented as the new source tree.

## Workflow rendering

`scripts/render-runtime-workflow.rb` reads the pinned Arrusted `WORKFLOW.md` and
may change only these infrastructure fields:

- `workspace.root`
- `worker.ssh_hosts`
- `worker.max_concurrent_agents_per_host`
- `agent.max_concurrent_agents`
- `server.host` and `server.port`

It creates one stable StatefulSet DNS host per replica, derives global
concurrency from replica capacity, preserves every other front-matter value,
and preserves the Markdown body byte-for-byte. It emits both source revisions
and the rendered checksum as provenance. There is no deployment-owned prose.

Render the complete production manifests from an exact workflow checkout:

```bash
bash scripts/render-production.sh \
  environments/production/desired-state.yaml \
  /path/to/arrusted-development-at-the-pinned-revision \
  rendered.yaml
```

## GitOps reconciliation

GitHub Actions is the reconciler:

- `validate.yml` proves source parity, render boundaries, scale safety,
  manifests, and images on every pull request.
- `publish-images.yml` publishes content-addressed images and opens a PR that
  updates committed digests. It never deploys an uncommitted digest.
- `reconcile-production.yml` runs after desired-state changes and hourly for
  drift repair. Production concurrency permits one reconcile operation.
- `production-diagnostics.yml` remains read-only.

The singleton orchestrator uses `Recreate`; two schedulers never overlap.
Scale-up makes the additional workers Ready before the expanded host inventory
is applied. Scale-down first applies the reduced inventory, restarts the
orchestrator, and queries Symphony's existing `/api/v1/state`. Any running or
retrying session on a removed host aborts before worker removal.

## Manual scaling

Change `spec.workers.replicas` in the desired-state file through a reviewed PR.
Do not use `kubectl scale` as the normal path. Automatic scaling is deliberately
out of scope for v1.

Workers use ephemeral task workspaces and pod-scoped, non-authoritative tool and
package caches. A replacement worker resumes from the pushed branch, pull
request, and Linear workpad. The worker image includes Git, SSH, GitHub CLI,
Codex, `mise`, `jq`, `zip`, and `unzip`.

## Local validation

```bash
ruby tests/test-runtime-workflow-renderer.rb
ruby tests/test-scale-down.rb
ARRUSTED_WORKFLOW_CHECKOUT=/path/to/pinned/arrusted-development \
  bash tests/test-production-render.sh
bash tests/test-worker-auth.sh
bash tests/test-worker-image-contract.sh
```

Production secrets are not committed. The desired state records their names;
the reconciler verifies that every referenced Secret exists before applying
anything. GitHub Actions additionally requires `DIGITALOCEAN_ACCESS_TOKEN` and
a revocable `ARRUSTED_REPOSITORY_TOKEN` with read-only access to the private
workflow repository. Reconciliation fails before rendering when either access
path is unavailable.
