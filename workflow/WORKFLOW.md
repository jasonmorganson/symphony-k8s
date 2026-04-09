---
tracker:
  kind: linear
  project_slug: __LINEAR_PROJECT_SLUG__
  api_key: $LINEAR_API_KEY

workspace:
  root: /srv/symphony/workspaces

worker:
  ssh_hosts:
    - symphony-worker-0.symphony-worker.symphony.svc.cluster.local
    - symphony-worker-1.symphony-worker.symphony.svc.cluster.local
    - symphony-worker-2.symphony-worker.symphony.svc.cluster.local
  max_concurrent_agents_per_host: 2

agent:
  max_concurrent_agents: 6
  max_turns: 20

codex:
  command: /usr/local/bin/codex app-server

hooks:
  after_create: |
    set -euo pipefail
    git clone __REPO_URL__ repo
    cd repo
    if [ -f package-lock.json ]; then
      npm ci
    elif [ -f pnpm-lock.yaml ]; then
      corepack enable && pnpm install --frozen-lockfile
    elif [ -f yarn.lock ]; then
      corepack enable && yarn install --frozen-lockfile
    fi
---

# Symphony Workflow

Update `tracker.project_slug` and clone URL placeholders before production use.
