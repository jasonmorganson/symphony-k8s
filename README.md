# Symphony Kubernetes (Skaffold) Scaffold

This repository provides a ready-to-run Kubernetes scaffold for running OpenAI Symphony with SSH-connected workers.

## Architecture

- `symphony-orchestrator` runs as a single central Deployment.
- `symphony-worker` runs as a StatefulSet with stable pod identities and per-pod storage.
- `symphony-runtime-base` is the shared runtime layer underneath both images.
- `symphony-release` is the out-of-band build image that compiles the Elixir release for the orchestrator.
- Orchestrator reaches workers over SSH stdio and launches `codex app-server` remotely.
- Workflow config and runtime secrets are generated only by the bootstrap overlay; routine production deploys preserve them.
- Workers get best-effort spread and anti-affinity so multi-node clusters keep replicas apart.

## Why StatefulSet For Workers

Workers need continuity for:

- stable DNS names for `worker.ssh_hosts`
- stable SSH host identity (known_hosts trust)
- durable per-worker workspace state

A Deployment does not guarantee stable pod identity or volume continuity, while StatefulSet does.

## Directory Layout

- `docker/runtime-base/`, `docker/release/`, `docker/orchestrator/`, `docker/worker/` image definitions
- `rust/` Kubernetes-native autoscaler and fail-closed workspace reclaimer
- `docker/common/` shared Docker runtime helpers
- `config/sshd_config.d/worker.conf` SSH daemon config drop-in for workers
- `k8s/base/` Kubernetes manifests
- `../arrusted-development/WORKFLOW.md` canonical prompt source (override with `SYMPHONY_WORKFLOW_FILE`)
- `config/workflow-runtime.yaml` Kubernetes-only front matter for worker routing, polling, and runtime limits
- `k8s/base/generated/skaffold/` Skaffold-generated workflow, SSH, and secret inputs

Docker builds use a tight root-level `.dockerignore` so workflow and generated
Kubernetes inputs do not constantly invalidate the images.

## Setup

### Skaffold-first setup

Export required configuration:

```bash
export LINEAR_API_KEY="lin_xxx"
export OPENAI_API_KEY="sk-xxx"
export SYMPHONY_WORKER_DRAIN_TOKEN="$(openssl rand -hex 32)"
export SYMPHONY_WORKFLOW_FILE="../arrusted-development/WORKFLOW.md"
# Optional, for private GitHub repos:
# export GITHUB_TOKEN="ghp_xxx"
```

Run Skaffold directly for local access:

```bash
skaffold dev
```

What Skaffold does automatically:

- runs `scripts/generate-skaffold-inputs.sh` to copy the canonical repository workflow and render SSH/secret inputs
- imports the prompt body from canonical `arrusted-development/WORKFLOW.md`
  while applying Kubernetes-only runtime front matter; it does not maintain a
  fork of the behavioral instructions
- records the Arrusted source revision in the content-addressed workflow ConfigMap
- generates `k8s/base/generated/skaffold/` inputs from your environment
- builds `symphony-runtime-base`, `symphony-release`, `symphony-orchestrator`,
  `symphony-worker`, and the Rust `symphony-autoscaler`
- renders the Kustomize base under `k8s/base/`
- creates the workflow ConfigMap and required Secrets from the generated files
- rolls the orchestrator when the canonical workflow content changes; worker
  credential changes remain operator-controlled through the StatefulSet's
  `OnDelete` update strategy
- deploys the orchestrator, workers, and services into `symphony`
- applies pod disruption budgets, ingress, and scheduling preferences
- forwards `symphony-orchestrator` to `http://127.0.0.1:4000` during `skaffold dev`

One-shot deploy for a real cluster:

```bash
skaffold run -p prod
```

Render manifests only:

```bash
skaffold render > rendered.yaml
```

If you want to inspect the generated inputs, they land under:

```bash
k8s/base/generated/skaffold/
```

There are no standalone helper scripts in the deploy path. Skaffold renders the workflow template and generates the SSH material directly from your environment.

Access the orchestrator UI/API from your host:

```text
http://127.0.0.1:4000
```

For local OrbStack access while using `run`, use Skaffold's built-in port forwarding:

```bash
skaffold run --tail --port-forward
```

That keeps the deployment running and forwards `symphony-orchestrator` to `http://127.0.0.1:4000`.

For remote clusters, use an ingress controller if one is available. The repo includes a basic `Ingress` that routes to `symphony-orchestrator` on port `4000`. The `symphony-orchestrator-public` `LoadBalancer` service remains available as a fallback on port `80`. In clusters without a provisioned external IP or ingress controller, port-forward the internal `ClusterIP` service:

```bash
kubectl -n symphony port-forward svc/symphony-orchestrator 4000:4000
```

On OrbStack, the `LoadBalancer` object may show an external IP but still not be reachable from the host. In that environment, Skaffold port forwarding in `run` mode is the reliable access path.

## Scheduling Notes

- Worker pods use preferred anti-affinity and topology spread constraints to keep replicas apart when the cluster has multiple nodes.
- Orchestrator pods prefer to land on a different node than workers.
- On a single-node cluster like OrbStack, these are best-effort preferences; Kubernetes cannot physically separate pods across nodes that do not exist.

## Required Secrets

These are generated by Skaffold from the env vars above and the live SSH key material:

- `symphony-secrets`
  - `LINEAR_API_KEY`
  - `OPENAI_API_KEY`
  - `SYMPHONY_WORKER_DRAIN_TOKEN` for authenticated scheduler drain updates
- `github-machine-arrusted-symphony`
  - `token` for the dedicated `autograph-symphony` machine user; create this
    Secret out of band and never commit the token
- `symphony-orchestrator-ssh`
  - `id_ed25519`
  - `known_hosts`
  - `config`
- `symphony-worker-authorized-keys`
  - `authorized_keys`
- `symphony-worker-hostkeys`
  - `ssh_host_ed25519_key`
  - `ssh_host_ed25519_key.pub`
- `codex-chatgpt-auth`
  - `auth.json` from a dedicated `codex login` using the personal ChatGPT
    account; create this Secret out of band and never commit the file
- `SYMPHONY_WORKFLOW_FILE`
  - path to the canonical `arrusted-development/WORKFLOW.md`; defaults to the adjacent repository checkout
- `config/workflow-runtime.yaml`
  - DOKS worker routing and runtime-only overrides; behavioral instructions do not belong here
- `config/workflow-throughput-overlay.md`
  - Git-tracked DOKS throughput policy appended to, but never substituted for, the canonical workflow
- `k8s/base/generated/skaffold/workflow/WORKFLOW.md`
  - exact generated copy used by the workflow ConfigMap
- `k8s/base/generated/skaffold/workflow/workflow-source.json`
  - source repository, exact Arrusted revision, and deployment overlay used by the deployment

## Caveats

- Stable SSH host keys are required. Do not rotate worker host keys without updating orchestrator `known_hosts`.
- Workers need persistent volumes for reliable continuation turns.
- Avoid a shared RWX workspace volume by default; use per-worker PVCs.
- Workers fail closed unless the dedicated machine credential authenticates as
  `autograph-symphony` and can read `withAutograph/arrusted-development`.
- This is an engineering-preview style setup and should be hardened before production use (RBAC, PodSecurity, image provenance, secret management, backup, and monitoring).

## DigitalOcean Kubernetes

`k8s/digitalocean` targets a managed DigitalOcean Kubernetes (DOKS) cluster.
It deliberately stays separate from the standalone `symphony-docker` Droplet:

- the dashboard remains a private `ClusterIP` service; the public
  `LoadBalancer` and `Ingress` resources are deleted
- one Symphony worker is used on the initial single-node pool
- orchestrator and worker workspaces use managed `do-block-storage` volumes
- runtime images are pulled from GHCR, so node replacement is safe

Production uses two separate node pools:

- `symphony-system` is fixed at two `s-2vcpu-4gb` nodes (about $48/month). It
  hosts the orchestrator, demand autoscaler, and Cloudflare connectors, and is
  tainted `symphony.morganson.me/workload=system:NoSchedule`.
- `symphony-ha` contains only `s-4vcpu-8gb` workers and autos-scales from zero
  to ten nodes. Active worker compute ranges from about $96 to $480/month.
  Each worker reserves 2 vCPU / 4 GiB and may use the node's full 4 vCPU with a
  6 GiB memory limit. The remaining memory is left for Kubernetes and system
  daemons. This prevents Codex plus the full repository gate from being killed
  at the previous 1.5 GiB limit.

The fixed system tier keeps the dashboard and wake-up controller available
when no worker nodes exist. DigitalOcean control-plane HA remains disabled and
would add a separate monthly charge.

### Demand-based autoscaling

The Rust `symphony-autoscaler` polls Symphony's existing state API every 15
seconds. It makes no Linear or GitHub request and receives neither credential.
Symphony reports eligible demand from candidate data already fetched by its
normal poll. Desired replicas are
`clamp(min, max, ceil(eligible / agents_per_worker))`, with bounds `0..10`.

Scale-up keeps new ordinals drained, increases StatefulSet replicas, and
watches worker pods with kube-rs. Ready workers are undrained on the next
idempotent reconciliation. Scale-up is immediate, while scale-down uses the
maximum validated desired capacity observed during the preceding 90 seconds.
The controller seeds that window with current capacity after restart and never
uses historical demand to scale above current capacity. Once the window
expires, scale-down drains the highest idle ordinals, requires Symphony to
acknowledge that those workers host no active session, and only then reduces
replicas. Any worker hosting a running session sets a hard capacity floor.

Stale or malformed Symphony state, an inexact drain acknowledgement, a failed
Kubernetes watch/relist, or any API error prohibits scale-down and retains
current capacity. `/healthz`, `/readyz`, and `/metrics` expose controller
health without a PVC or usage ledger. Merging uses upstream Symphony's normal
global and per-worker capacity; this deployment adds no Merging-specific limit.

Each worker also runs the Rust workspace reclaimer against only its canonical
PVC root. It ignores unknown or nonterminal issues, requires the configured
terminal-age grace plus two successful terminal observations, and refuses
cleanup when Symphony state or any workspace path is uncertain. It rechecks
Symphony after the bounded Linear lookup before deleting. Symlinks and root
escapes fail closed; observation state is replaced atomically.

The DOKS deploy entrypoint regenerates these inputs only from a clean,
up-to-date Arrusted `main` checkout. It rejects dirty, non-`main`, or stale
workflow sources before calling `kubectl apply`. Kustomize's generated
ConfigMap name includes the workflow and source record contents, so any change
rolls the orchestrator.
The deploy source itself must also be clean, current `master`. The entrypoint
resolves the autoscaler image published under that exact Git revision and
substitutes its immutable GHCR digest into the rendered manifest; callers
cannot supply an unrelated or mutable image.

Each worker has strict hostname spreading, so a pending worker makes the DOKS
Cluster Autoscaler add a node. Configure `symphony-ha` with minimum 0 and
maximum 10 nodes. StatefulSet PVCs are retained after scale-down so work can
resume safely; those block-storage volumes continue to incur storage charges.
The worker StatefulSet uses `OnDelete` updates so manifest or image changes do
not terminate active SSH sessions. Roll worker ordinals manually only after the
dashboard reports that the target worker is idle; replica scaling remains under
the autoscaler's control.

To distinguish the tiers operationally:

```bash
kubectl get nodes -L doks.digitalocean.com/node-pool
kubectl -n symphony get pods -o wide
```

### Personal Codex authentication

Production workers use the personal ChatGPT Codex entitlement and fail closed;
they never fall back to API-key billing. Create or rotate the authentication
Secret without putting credential JSON in a manifest or command argument:

```bash
codex login status # must report: Logged in using ChatGPT
KUBECONFIG="$HOME/.kube/symphony-doks.yaml" \
  kubectl -n symphony create secret generic codex-chatgpt-auth \
    --from-file=auth.json=/dev/stdin \
    --dry-run=client -o yaml < "$HOME/.codex/auth.json" | \
  KUBECONFIG="$HOME/.kube/symphony-doks.yaml" \
  kubectl apply --server-side -f -
```

Each worker seeds a private `codex-home` directory on its existing workspace
PVC. Refreshed credentials therefore survive pod and node replacement and are
not shared through a writable filesystem. The seed Secret is used only when a
worker has no persisted `auth.json`.

Verify authentication without displaying credential material:

```bash
for pod in $(kubectl -n symphony get pods -l app=symphony-worker -o name); do
  kubectl -n symphony exec "$pod" -c worker -- \
    runuser -u symphony -- env HOME=/home/symphony codex login status
done
```

If the ChatGPT grant is revoked, rotate the Secret and remove each persisted
`codex-home/auth.json` before restarting the StatefulSet so it is reseeded.
Workers remain unready when authentication is missing or API-key based. The
status check identifies the stored authentication mode; expired or revoked
grants surface on the next Codex request and never trigger API fallback. Keep
the project API key only as an operator-controlled rollback secret; the worker
pod does not receive it. An API rollback must restore both the prior image and
the prior `envFrom: symphony-secrets` worker configuration.

### GitHub and Vercel machine identity

Every worker uses the dedicated `autograph-symphony` GitHub account for Git
HTTPS, GitHub CLI operations, commits, pushes, pull requests, comments, and
review responses. The worker entrypoint verifies the token's live GitHub login
and private-repository access before starting SSH, then fixes Git authorship to
`autograph-symphony <jason+symphony@withgraph.com>` with `user.useConfigOnly`.
It does not fall back to a personal token or the legacy GitHub App.

Create or rotate the machine credential from standard input so it does not
appear in a manifest or command argument:

```bash
read -rs GITHUB_MACHINE_TOKEN
printf '\n'
printf '%s' "$GITHUB_MACHINE_TOKEN" | \
  KUBECONFIG="$HOME/.kube/symphony-doks.yaml" \
  kubectl -n symphony create secret generic github-machine-arrusted-symphony \
    --from-file=token=/dev/stdin \
    --dry-run=client -o yaml | \
  KUBECONFIG="$HOME/.kube/symphony-doks.yaml" \
  kubectl apply --server-side -f -
unset GITHUB_MACHINE_TOKEN
```

The token is mounted only as a worker environment value. Ephemeral `.netrc`,
GitHub CLI, and Git identity
configuration are recreated on every worker pod start; they are not stored in
workspace or Codex-home PVCs. A missing, expired, wrong-user, or
repository-inaccessible credential leaves the worker unready and the handoff
fail-closed.
Vercel's native Git integration remains the deployment path; this repository
does not add a GitHub Actions Vercel deployment.

Verify identity without displaying credential material:

```bash
for pod in $(kubectl -n symphony get pods -l app=symphony-worker -o name); do
  kubectl -n symphony exec "$pod" -c worker -- sh -c \
    'gh api user --jq .login && git config --global --get-regexp "^user\\."'
done
```

Keep `github-app-arrusted-symphony` installed only for an operator-controlled
rollback window. Remove that installation and its Kubernetes Secret only after
a machine-authored Symphony PR receives its native Vercel preview and the
machine credential survives worker restart and rescheduling.

The pre-migration cost baseline on 2026-07-12 was approximately 49.5 million
input tokens and 88 thousand output tokens; the later live total reached 68.9
million input tokens. One issue consumed about 7.6 million input tokens across
four agent turns. The optimized workflow uses medium rather than xhigh reasoning,
permits one agent per worker,
polls every 15 seconds, and dispatches `Human Review` only for bounded readiness
maintenance. That lane may repair an attached pull request's conflicts or concrete
gate failure and reconcile stale evidence or coordination, but cannot infer approval,
merge, broaden acceptance work, or transition the issue.
It also bounds the Linear workpad and consolidates asynchronous review findings
before a full-repository gate on the final code-bearing tree, avoiding repeated
context resubmission and full validation for each overlapping review comment.
Later feedback-driven code changes invalidate and rerun that gate.
Required review panels inspect the diff and existing evidence; they use targeted
reproductions for suspected defects instead of each launching the same full
matrix. The primary agent owns the authoritative final gate.
Codex is capped at three threads per issue: one primary plus up to two independent
reviewers, rather than the six-thread default. With five Symphony workers this
bounds worst-case model fan-out at 15 threads instead of 30.
A 120,000-token Codex auto-compaction override was tested and removed: during
the short live A-142 debugging segment it showed no benefit and coincided with
a higher observed input-token slope while adding compaction work. The workflow
uses the model default.

Current-session state, eligible demand, read-only observed issue dwell, and
worker-pool capacity are available from Symphony's state API. `Human Review`
is included in active demand and dispatch, and its prompt contract limits work
to readiness maintenance while preserving explicit human approval. When no
maintenance is actionable, the agent leaves the issue in `Human Review` and
uses Symphony's bounded deferred recheck instead of consuming immediate turns.
Autoscaler health and capacity measurements are available from its metrics
endpoint:

```bash
kubectl -n symphony port-forward svc/symphony-orchestrator 4000:4000
curl -fsS http://127.0.0.1:4000/api/v1/state | jq \
  '{demand, observed, worker_pool, running, retrying, codex_totals}'
kubectl -n symphony port-forward svc/symphony-autoscaler 8080:8080
curl -fsS http://127.0.0.1:8080/metrics
```

Pause automatic worker changes during an incident:

```bash
kubectl -n symphony scale deployment/symphony-autoscaler --replicas=0
```

Apply a temporary manual worker count while the scaler is paused:

```bash
kubectl -n symphony scale statefulset/symphony-worker --replicas=2
```

Inspect health and metrics without exposing secrets:

```bash
kubectl -n symphony port-forward svc/symphony-autoscaler 8080:8080
curl http://127.0.0.1:8080/metrics
```

Build and publish the amd64 runtime images:

```bash
docker build --platform linux/amd64 -t symphony-runtime-base:do -f docker/runtime-base/Dockerfile .
docker build --platform linux/amd64 -t symphony-release:do -f docker/release/Dockerfile .
docker build \
  --platform linux/amd64 \
  --build-arg RUNTIME_BASE=symphony-runtime-base:do \
  --build-arg SYMPHONY_RELEASE_IMAGE=symphony-release:do \
  -t ghcr.io/jasonmorganson/symphony-k8s-orchestrator:20260712 \
  -f docker/orchestrator/Dockerfile .
docker build \
  --platform linux/amd64 \
  --build-arg RUNTIME_BASE=symphony-runtime-base:do \
  -t ghcr.io/jasonmorganson/symphony-k8s-worker:20260712 \
  -f docker/worker/Dockerfile .
docker build \
  --platform linux/amd64 \
  -t ghcr.io/jasonmorganson/symphony-k8s-autoscaler:20260712 \
  -f docker/autoscaler/Dockerfile .
docker push ghcr.io/jasonmorganson/symphony-k8s-orchestrator:20260712
docker push ghcr.io/jasonmorganson/symphony-k8s-worker:20260712
docker push ghcr.io/jasonmorganson/symphony-k8s-autoscaler:20260712
```

Merges to `master` automatically build all three images, resolve immutable
digests, quiesce new admissions, and restart immediately through GitHub Actions.
The deployment snapshots the existing worker drains, pauses the autoscaler, and
drains every worker from new admissions. Active sessions may be interrupted and
are recovered through Symphony retry or rediscovery. Set
`SYMPHONY_WAIT_FOR_IDLE=true` for an explicitly graceful rollout; that opt-in
wait is bounded to four hours. The deployment holds the autoscaler at zero until the orchestrator and
every `OnDelete` worker pod are running the requested immutable digests. It
verifies source annotations, workload templates, and ready pod image IDs before
restoring the exact prior drain set, then restores and verifies the autoscaler.
A failure after apply keeps admissions quiesced unless their final restoration
already succeeded; a pre-apply failure restores the original admission state.
An unavailable or malformed state endpoint fails
closed before any provider or
cluster mutation. The `production` GitHub environment supplies
`DIGITALOCEAN_ACCESS_TOKEN`; restrict that token to
`kubernetes:access_cluster`, `kubernetes:update`, and the required read scopes.
Each run downloads a kubeconfig with a ten-minute lifetime.

Routine manual deployment uses the CD-safe `k8s/digitalocean` overlay. It does
not render or update Secrets or the `symphony-workflow` ConfigMap:

```bash
ORCHESTRATOR_IMAGE="ghcr.io/jasonmorganson/symphony-k8s-orchestrator@sha256:..." \
WORKER_IMAGE="ghcr.io/jasonmorganson/symphony-k8s-worker@sha256:..." \
AUTOSCALER_IMAGE="ghcr.io/jasonmorganson/symphony-k8s-autoscaler@sha256:..." \
SOURCE_REVISION="$(git rev-parse HEAD)" \
bash scripts/deploy-digitalocean.sh
```

For an initial installation or explicit credential/workflow rotation, generate
the ignored inputs and opt into the root bootstrap overlay:

```bash
bash scripts/generate-skaffold-inputs.sh
DEPLOY_BOOTSTRAP_RUNTIME=true bash scripts/deploy-digitalocean.sh
rm -rf k8s/base/generated
```

The generator retains the canonical `arrusted-development/WORKFLOW.md` prompt
and appends `config/workflow-throughput-overlay.md`. Because the resulting
`symphony-workflow` ConfigMap remains bootstrap-only, merging an overlay change
does not mutate the live prompt. Regenerate and apply it only during an explicit
idle workflow rotation after reviewing the generated `WORKFLOW.md`.

The wrapper preflights the required DOKS add-ons, reconciles the `symphony-ha`
pool to autoscaling bounds `0..10`, renders and validates in a temporary
directory, applies without pruning, then
idempotently pins CoreDNS and konnectivity plus any enabled Hubble relay/UI
deployments to the fixed `symphony-system` pool with its required taint
toleration. Override the provider targets with `DOKS_CLUSTER` and
`SYMPHONY_WORKER_NODE_POOL`; override the bounds with
`SYMPHONY_WORKER_MIN_NODES` and `SYMPHONY_WORKER_MAX_NODES`. Run the wrapper
after every DOKS upgrade as well as every Symphony deployment so provider-managed
add-on changes cannot leave critical replicas stranded on an autoscaled worker
node and block scale-to-zero. The wrapper replaces drained `OnDelete` worker
pods from highest to lowest ordinal, waits for each replacement to become ready,
and refuses success unless every runtime image ID matches its requested digest.

Never commit or retain `k8s/base/generated`: it temporarily contains plaintext
secret inputs. Remove the generated directory immediately after bootstrap or
rotation. Automatic CD never reads or copies this directory. The three GHCR packages must be public before the first
deploy; verify each manifest can be pulled without registry credentials. The
DOKS overlay always pulls the configured images and relaxes both disruption budgets
to permit managed single-node drains and upgrades. A drain necessarily causes a
brief outage until the replacement node is ready.

Access the private dashboard through the Kubernetes API:

```bash
kubectl -n symphony port-forward svc/symphony-orchestrator 4000:4000
```

Then open <http://127.0.0.1:4000>. DOKS restarts failed pods automatically, and
the managed block volumes survive pod and worker-node replacement. Keep the
dashboard private until an authenticated ingress is added.

### Protected dashboard access

The public dashboard is published at <https://symphony.morganson.me> through a
remotely managed Cloudflare Tunnel. The Kubernetes service remains a private
`ClusterIP`: no DigitalOcean LoadBalancer, Ingress, NodePort, or inbound
firewall rule is used. Cloudflare Access protects every path with GitHub login
and allows only `jasonmorganson@gmail.com` for a 24-hour session.

The tunnel token is stored only in the live `cloudflare-tunnel-token` Secret.
Create or rotate it without putting plaintext in a command argument or file:

```bash
read -rs CLOUDFLARE_TUNNEL_TOKEN
printf '\n'
printf '%s' "$CLOUDFLARE_TUNNEL_TOKEN" | \
  KUBECONFIG="$HOME/.kube/symphony-doks.yaml" \
  kubectl -n symphony create secret generic cloudflare-tunnel-token \
    --from-file=token=/dev/stdin \
    --dry-run=client -o yaml | \
  KUBECONFIG="$HOME/.kube/symphony-doks.yaml" \
  kubectl apply --server-side -f -
unset CLOUDFLARE_TUNNEL_TOKEN
KUBECONFIG="$HOME/.kube/symphony-doks.yaml" \
  kubectl -n symphony rollout restart deployment/cloudflared
```

Deleting or disabling the public hostname route or Tunnel stops public
dashboard access but does not stop Symphony. For immediate incident
containment, scale `deployment/cloudflared` to zero or install an explicit
deny-all Access policy. Never disable or delete the Access application while the
public hostname route remains active, because that can remove the authentication
gate. The authenticated local break-glass path remains available:

```bash
KUBECONFIG="$HOME/.kube/symphony-doks.yaml" \
  kubectl -n symphony port-forward svc/symphony-orchestrator 4000:4000
```

Useful tunnel checks:

```bash
KUBECONFIG="$HOME/.kube/symphony-doks.yaml" \
  kubectl -n symphony rollout status deployment/cloudflared
KUBECONFIG="$HOME/.kube/symphony-doks.yaml" \
  kubectl -n symphony logs -l app=cloudflared --tail=100
curl -sS -o /dev/null -D - https://symphony.morganson.me/
KUBECONFIG="$HOME/.kube/symphony-doks.yaml" \
  kubectl -n symphony get svc,ingress
```

An unauthenticated request must redirect to Cloudflare Access, the service list
must contain no LoadBalancer or NodePort, and the ingress list must be empty.
Also verify in Cloudflare that the application covers the whole hostname, uses
only GitHub instant authentication, has a 24-hour session, contains one Allow
rule for `jasonmorganson@gmail.com`, and contains no Everyone or Bypass policy.
Test live dashboard updates from an authenticated browser before considering a
tunnel change complete.

The two connector replicas protect against a single `cloudflared` process
failure. They run on the same initial DOKS node and therefore do not provide
node-level availability; Kubernetes recreates them after node replacement.

Never commit the tunnel token. Anyone holding it can run a connector for this
tunnel; rotate it immediately if it appears in logs, manifests, CI output, or
shell history.

## Namespace Kubernetes

The live Namespace deployment is a separate Kubernetes compute instance, not
the `symphony-docker` VM deployment. Create one with:

```bash
nsc create \
  --enable=kubernetes:1.33 \
  --machine_type linux/amd64:8x16 \
  --duration 2h \
  --wait_kube_system \
  --label app=symphony-k8s \
  --unique_tag symphony-k8s
```

Namespace compute is leased. Kubernetes restarts failed containers and retains
PVC data while the instance exists, but it cannot prevent the instance deadline
from expiring. This workspace currently caps the effective lease near three
hours even when a longer duration is requested. Run renewal outside the
instance (for example from `launchd` or CI) at least every hour:

```bash
scripts/renew-namespace-instance.sh INSTANCE_ID 2h
```

`.github/workflows/namespace-keepalive.yml` performs that renewal and verifies
both Kubernetes rollouts hourly. It authenticates with the repository secret
`NSC_TOKEN_FILE_JSON`, containing a revocable Namespace token file scoped to
the instance's `refresh`, `get`, `dial_host`, and `exec` permissions. Rotate
that token at least annually and whenever repository administration changes.

The image references in `k8s/base/kustomization.yaml` point at the Namespace
workspace registry. Build and push all four images before applying the base.
Generate inputs with `scripts/generate-skaffold-inputs.sh`, apply them, and
immediately remove `k8s/base/generated`; generated secret material is ignored
by Git and must never be committed.

Keep the dashboard private because the pinned Symphony dependency lock contains
known HTTP denial-of-service advisories. Access it through an authenticated
local tunnel:

```bash
nsc kubectl INSTANCE_ID -n symphony port-forward svc/symphony-orchestrator 4000:4000
```

Then open <http://127.0.0.1:4000>. Do not run `nsc expose kubernetes` until an
authentication proxy and patched upstream dependencies are in place.

Useful checks:

```bash
nsc kubectl INSTANCE_ID -n symphony get pods,pvc
nsc kubectl INSTANCE_ID -n symphony logs -f deploy/symphony-orchestrator
nsc kubectl INSTANCE_ID -n symphony rollout status statefulset/symphony-worker
```
