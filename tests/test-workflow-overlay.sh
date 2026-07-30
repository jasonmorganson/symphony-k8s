#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

runtime="$TEMP_DIR/runtime.yaml"
canonical="$TEMP_DIR/WORKFLOW.md"
overlay="$TEMP_DIR/overlay.md"

printf '%s\n' 'tracker:' '  kind: linear' > "$runtime"
printf '%s\n' \
  '---' \
  'tracker:' \
  '  kind: linear' \
  '---' \
  '# Canonical workflow' \
  'Canonical instruction.' \
  > "$canonical"
printf '%s\n' '# Deployment overlay' 'Overlay instruction.' > "$overlay"

"$ROOT_DIR/scripts/render-workflow.sh" \
  "$runtime" "$canonical" "$overlay" > "$TEMP_DIR/rendered.md"

[[ "$(grep -c '^tracker:$' "$TEMP_DIR/rendered.md")" == 1 ]]
grep -Fqx '# Canonical workflow' "$TEMP_DIR/rendered.md"
grep -Fqx 'Canonical instruction.' "$TEMP_DIR/rendered.md"
grep -Fqx '# Deployment overlay' "$TEMP_DIR/rendered.md"
grep -Fqx 'Overlay instruction.' "$TEMP_DIR/rendered.md"
canonical_line="$(grep -nF '# Canonical workflow' "$TEMP_DIR/rendered.md" | cut -d: -f1)"
overlay_line="$(grep -nF '# Deployment overlay' "$TEMP_DIR/rendered.md" | cut -d: -f1)"
(( canonical_line < overlay_line ))

"$ROOT_DIR/scripts/render-workflow.sh" \
  "$runtime" "$canonical" "$ROOT_DIR/config/workflow-throughput-overlay.md" \
  > "$TEMP_DIR/throughput-rendered.md"
grep -Fqx '# DOKS Linear-read guard' "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'finite page size of at most 25' "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'This read guard does not alter upstream' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'dispatch, Merging, landing, or Linear-transition behavior.' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fqx '# Preserve active issue state across orchestration control flow' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'Never move an existing active issue in `In Progress`, `Human Review`, `Merging`, or `Rework`' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq '`Backlog` is reserved for newly created out-of-scope follow-up issues' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fqx '# Preserve explicit merge authority' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'Merge authority is revoked by default deployment-wide.' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'Symphony must not manufacture authority by' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'An issue already in `Merging` when Symphony admits it is an explicit operator-authored,' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'return it to `Human Review` solely because authority is revoked by default' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'Leave the operator-owned transition as the only way to grant issue-specific merge' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'Only when the durable workpad proves that' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'post-merge reconciliation rules below take' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'Never re-evaluate the default authority revocation' \
  "$TEMP_DIR/throughput-rendered.md"

grep -Fq 'symphony-workflow-overlay' \
  "$ROOT_DIR/k8s/base/orchestrator-deployment.yaml"
grep -Fq '/workflow-overlay/workflow-throughput-overlay.md' \
  "$ROOT_DIR/k8s/base/orchestrator-deployment.yaml"
grep -Fq 'mountPath: /etc/symphony-workflow' \
  "$ROOT_DIR/k8s/base/orchestrator-deployment.yaml"
grep -Fq 'create configmap symphony-workflow-overlay' \
  "$ROOT_DIR/scripts/deploy-digitalocean.sh"
grep -Fqx '# Recover an explicitly stranded active issue' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'This recovery rule has higher precedence than every generic `Backlog -> stop`' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'do not execute those generic Backlog routes' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'canonical workflow-owned Linear transition as the first action' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'Do not end, yield, or defer the' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'Recovery never authorizes merge, provider' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fqx '# Retire the removed Arrusted requester-policy contract' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'target repository has deliberately removed' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'higher precedence than the legacy' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'do not block PR creation because the mapping is absent' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'sole publication blocker' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'recover it to `In Progress` through the canonical' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'bounded publication recovery' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fqx '# Consolidated review for mechanical main-CI repairs' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'one consolidated required review panel' "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'authoritative final gate on the final tree' "$TEMP_DIR/throughput-rendered.md"
grep -Fqx '# Durable review proof across session boundaries' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'completed Review Batch remains valid across a continuation' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'committed, staged, unstaged, untracked' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'do not launch another panel solely because the session' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'Fail closed and run the canonical required review again' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq "never satisfies or replaces the primary agent's authoritative final gate" \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fqx '# Bound provider evidence probes' "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'non-interactive timeout of at most 90 seconds' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'Skipped hosted CI on a draft pull request is not executable validation' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq "Inspect the skipped job's checked workflow definition" \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'different broader gate is not a substitute' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'Do not make a draft ready merely to cause CI to run' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fqx '# Bound work when the reported failure does not reproduce' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'make an explicit scope decision' "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'new repository-wide enforcement framework' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'Failure to reproduce does not waive any remaining acceptance criterion' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fqx '# Freeze a published head while its evidence is pending' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'keep the code-bearing tree fixed' "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'Do not add speculative cleanup, helper extraction, extra tests' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'only in response to a concrete classified check failure' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'produce one bounded remediation batch' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fqx '# Do not wait for a CI job that is not part of the current gate' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'inspect the checked workflow, its change classifier' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'acceptance criteria assign its authoritative proof' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'Do not retry, edit code, or hold a review-ready issue' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'Fail closed when a ruleset-required or acceptance-required pre-merge job' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fqx '# Serialize gates that share repository-visible temporary state' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'Run gates sequentially when either gate creates' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'orchestration interference, not a product finding' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fqx '# Dependency-upgrade scope budget' "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'explicit scope-budget decision in the durable workpad' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq "ticket's bounded exception" "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'Do not silently turn a package update into a provider-tool migration' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fqx '# Fresh remote proof in Merging' "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'explicit authenticated fetch of the target branch' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'publish that exact head immediately with `--force-with-lease`' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'Do not hold a publishable rebase repair behind those long gates.' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'treat the earlier hosted run as superseded' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'Never merge until the final remote head is clean' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'Staleness alone never returns an authorized issue to `Human Review`' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fqx '# Human Review maintenance lane' "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'Treat `Human Review` as an active maintenance lane' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'repair only the concrete conflict' "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'required hosted job that was skipped lacks a durable exact-command local receipt' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'deferring this lane for provider or human evidence' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'do not create a parent branch or pull' "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'must never merge, close, or approve a pull request' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'transition the issue to `Merging`, `Done`, `In Progress`, `Rework`' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'broaden acceptance criteria' "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'leave the issue in `Human Review` and call' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'outcome `defer` as the final' "$TEMP_DIR/throughput-rendered.md"
grep -A6 '^  active_states:$' "$ROOT_DIR/config/workflow-runtime.yaml" |
  grep -Fq '    - Human Review'
if grep -A5 '^  observed_states:$' "$ROOT_DIR/config/workflow-runtime.yaml" |
    grep -Fq 'Human Review'; then
  echo "Human Review must not be duplicated in observed states" >&2
  exit 1
fi
grep -Fq 'exact fetched target SHA and the ancestry result' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fqx '# Retain Merging through post-merge verification' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'keep the issue in `Merging` while required' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'Never move the issue from `Merging` to `In Progress`, `Human' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'containing-main proof has not completed yet' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq "Resolve and freeze the issue's containing-main revision" \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'agent turn open with `gh run watch`' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'issue on a later rate-limited turn' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'do not advance the proof target to a newer' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq "subsequent commits cannot invalidate the" \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'transition the issue directly from `Merging` to' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'When a required post-merge gate fails, keep' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'the issue in `Merging` and follow the canonical failure-repair' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'only a routing shorthand into this post-merge reconciliation' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'Pending, missing, stale, or ambiguous evidence is not success.' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fqx '# Require terminal evidence before a successor repair' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'Do not open, reopen, or move an issue into an active successor-repair lane' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'while the authoritative' "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'containing-main gate for the alleged owning change is still pending' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'Only a terminal authoritative failure may create or reactivate a successor repair' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'terminal successful containing-main gate disproves the proposed successor lane' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fqx '# Recover issues bounced after merge' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'if an `In Progress` or `Rework` issue has exactly one' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'route directly to' "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'post-merge reconciliation before reproducing, planning, editing, reviewing, or running' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'transition the issue directly to `Done` using the canonical workflow-owned' \
  "$TEMP_DIR/throughput-rendered.md"
grep -Fq 'Do not create a successor branch, rerun the implementation test suite' \
  "$TEMP_DIR/throughput-rendered.md"
if grep -Eq 'symphony_merge_writer|"action":"(yield|acquire|release)"' \
    "$TEMP_DIR/throughput-rendered.md"; then
  echo "throughput overlay must not serialize Merging work" >&2
  exit 1
fi

printf '%s\n' \
  '---' \
  'tracker:' \
  '  active_states:' \
  '    - Todo' \
  '  observed_states:' \
  '    - Human Review' \
  'agent:' \
  '  max_concurrent_agents: 1' \
  '---' \
  '# Canonical workflow' \
  'Canonical instruction.' \
  '# DOKS Linear-read guard' \
  'Stale deployment overlay.' \
  > "$TEMP_DIR/mounted-workflow.md"
"$ROOT_DIR/docker/orchestrator/materialize-runtime-workflow.sh" \
  "$ROOT_DIR/config/workflow-runtime.yaml" \
  "$TEMP_DIR/mounted-workflow.md" \
  "$ROOT_DIR/config/workflow-throughput-overlay.md" \
  "$TEMP_DIR/runtime-workflow.md"
[[ "$(grep -c '^tracker:$' "$TEMP_DIR/runtime-workflow.md")" == 1 ]]
grep -A6 '^  active_states:$' "$TEMP_DIR/runtime-workflow.md" |
  grep -Fq '    - Human Review'
if grep -A5 '^  observed_states:$' "$TEMP_DIR/runtime-workflow.md" |
    grep -Fq 'Human Review'; then
  echo "runtime workflow must replace stale mounted tracker front matter" >&2
  exit 1
fi
if grep -Fqx '  max_concurrent_agents: 1' "$TEMP_DIR/runtime-workflow.md"; then
  echo "runtime workflow must not retain stale mounted runtime limits" >&2
  exit 1
fi
grep -Fqx 'Canonical instruction.' "$TEMP_DIR/runtime-workflow.md"
grep -Fqx '# Consolidated review for mechanical main-CI repairs' \
  "$TEMP_DIR/runtime-workflow.md"
grep -Fqx '# Preserve active issue state across orchestration control flow' \
  "$TEMP_DIR/runtime-workflow.md"
grep -Fq 'On interruption, leave the issue state unchanged' \
  "$TEMP_DIR/runtime-workflow.md"
grep -Fqx '# Durable review proof across session boundaries' \
  "$TEMP_DIR/runtime-workflow.md"
grep -Fqx '# Bound work when the reported failure does not reproduce' \
  "$TEMP_DIR/runtime-workflow.md"
grep -Fqx '# Freeze a published head while its evidence is pending' \
  "$TEMP_DIR/runtime-workflow.md"
grep -Fqx '# Do not wait for a CI job that is not part of the current gate' \
  "$TEMP_DIR/runtime-workflow.md"
grep -Fqx '# Serialize gates that share repository-visible temporary state' \
  "$TEMP_DIR/runtime-workflow.md"
grep -Fqx '# Dependency-upgrade scope budget' "$TEMP_DIR/runtime-workflow.md"
grep -Fqx '# Fresh remote proof in Merging' "$TEMP_DIR/runtime-workflow.md"
grep -Fq 'publish that exact head immediately with `--force-with-lease`' \
  "$TEMP_DIR/runtime-workflow.md"
grep -Fq 'Never merge until the final remote head is clean' \
  "$TEMP_DIR/runtime-workflow.md"
grep -Fqx '# Retain Merging through post-merge verification' \
  "$TEMP_DIR/runtime-workflow.md"
grep -Fqx '# Require terminal evidence before a successor repair' \
  "$TEMP_DIR/runtime-workflow.md"
grep -Fqx '# Recover issues bounced after merge' \
  "$TEMP_DIR/runtime-workflow.md"
if grep -Fq 'Stale deployment overlay.' "$TEMP_DIR/runtime-workflow.md"; then
  echo "runtime workflow must replace the stale mounted deployment overlay" >&2
  exit 1
fi
[[ "$(grep -Fc '# DOKS Linear-read guard' "$TEMP_DIR/runtime-workflow.md")" == 1 ]]
grep -Fq '/tmp/symphony-workflow/WORKFLOW.md' \
  "$ROOT_DIR/k8s/base/orchestrator-deployment.yaml"
grep -Fq 'materialize-runtime-workflow.sh' \
  "$ROOT_DIR/docker/orchestrator/entrypoint.sh"
grep -Fq 'workflow-runtime.yaml' "$ROOT_DIR/docker/orchestrator/entrypoint.sh"
grep -Fq 'config/workflow-runtime.yaml' "$ROOT_DIR/docker/orchestrator/Dockerfile"

if "$ROOT_DIR/scripts/render-workflow.sh" \
    "$runtime" "$canonical" "$TEMP_DIR/missing.md" >/dev/null 2>&1; then
  echo "missing throughput overlay must fail closed" >&2
  exit 1
fi

: > "$overlay"
if "$ROOT_DIR/scripts/render-workflow.sh" \
    "$runtime" "$canonical" "$overlay" >/dev/null 2>&1; then
  echo "empty throughput overlay must fail closed" >&2
  exit 1
fi

echo "workflow overlay tests passed"
