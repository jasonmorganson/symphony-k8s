# DOKS Linear-read guard

Use the issue snapshot supplied by Symphony and the durable workpad as the normal source of issue
context. When an authoritative Linear refresh is necessary, request only the fields needed for the
current decision, use a finite page size of at most 25, and stop pagination as soon as that
decision can be made.

Do not replace a missing or ambiguous bounded result with an unbounded query for issue history,
comments, attachments, relations, or workpad content. This read guard does not alter upstream
dispatch, Merging, landing, or Linear-transition behavior.

# Preserve active issue state across orchestration control flow

Never move an existing active issue in `In Progress`, `Human Review`, `Merging`, or `Rework` to
`Backlog` as a retry, yield, defer, interruption, max-turn, restart, capacity, or scheduler-control
mechanism. On interruption, leave the issue state unchanged so Symphony can resume it through the
normal active-state lane.

For a real external blocker, use the canonical documented `Human Review` escape and preserve its
required evidence. `Backlog` is reserved for newly created out-of-scope follow-up issues; it is not
a parking state for work Symphony has already admitted.

# Recover an explicitly stranded active issue

If Symphony admits an existing issue whose current state is outside the configured active states,
the operator has explicitly selected that issue for recovery; this is not general Backlog
admission. This recovery rule has higher precedence than every generic `Backlog -> stop`, `do not
modify`, or `wait for human` rule elsewhere in this workflow. For an explicitly admitted recovery
target, do not execute those generic Backlog routes.

Re-read the issue's current state and durable workpad. Only when they prove the issue was already
active and was moved out of the active lane solely as an orchestration, review-freeze, or
concurrency lock, restore it to its most recent appropriate active implementation state using the
canonical workflow-owned Linear transition as the first action. Do not end, yield, or defer the
turn before attempting that transition. Then continue from the existing workspace and exact
published branch state.

If the evidence instead shows a genuine unstarted Backlog issue, completed or canceled work, an
ambiguous owner, or a real external blocker, do not transition or implement it. Report `defer` and
leave the item unchanged for operator correction. Recovery never authorizes merge, provider
mutation, relaxed exact-head gates, a new branch, or a competing writer.

# Human Review maintenance lane

Treat `Human Review` as an active maintenance lane, not as approval to resume product work. Inspect
only the issue's current attached pull request, required checks and provider evidence, and durable
workpad or child-issue coordination facts. Perform maintenance only when current evidence identifies
one of these concrete readiness defects:

- the single unambiguous attached open pull request conflicts with or is stale against its freshly
  fetched target branch;
- a required check or provider proof is failing, missing, or stale for the attached pull request;
  a required hosted job that was skipped lacks a durable exact-command local receipt on the current
  published head; or
- the durable workpad or parent/child coordination record is stale relative to current pull-request,
  gate, or child-issue facts.

For an attached pull request, preserve its accepted scope and repair only the concrete conflict,
check failure, or evidence defect on that same branch and pull request. Run only the validation
invalidated by the repair, then refresh the exact readiness evidence. For coordination-only parent
issues, reconcile current facts in the existing workpad; do not create a parent branch or pull
request. A merged or closed attached pull request is evidence to reconcile, not authorization to
reopen it, create a successor, or perform more implementation.

An unavailable provider receipt never makes an independent repository gate non-actionable. Before
deferring this lane for provider or human evidence, execute and record every missing independent
repository gate, including the exact workflow command, environment, and arguments for a required
hosted job skipped because the pull request is draft. A broad aggregate gate does not satisfy that
receipt unless the checked workflow invokes the same command with the same environment and
arguments.

This lane must never merge, close, or approve a pull request; infer, manufacture, dismiss, or replace
human approval; transition the issue to `Merging`, `Done`, `In Progress`, `Rework`, or any other
state; broaden acceptance criteria; add product scope; perform generalized cleanup; or create a new
branch or pull request. Preserve explicit human approval and all canonical review, CI, deployment,
credential-isolation, and final-gate requirements. Maintenance that changes the pull-request head
must report the new head and current approval/evidence truth without claiming that an approval for
an older head remains current.

After the bounded maintenance is complete, or when no listed readiness defect is actionable,
leave the issue in `Human Review` and call `symphony_report_turn_outcome` with outcome `defer` as the final
tool action. State in the reason whether maintenance completed or current external/human
evidence is unchanged. This hint schedules only a bounded authoritative tracker recheck; it never
represents approval or a tracker transition.

# Consolidated review for mechanical main-CI repairs

When a main-CI repair is a sequence of mechanical or generated-only commits, finish the complete
repair series and present its final code-bearing tree to one consolidated required review panel.
Do not rerun an otherwise identical panel after each mechanical commit. The panel must inspect the
aggregate diff and the existing targeted evidence, and the primary agent must still run the
authoritative final gate on the final tree.

This consolidation does not waive required review, CI, deployment safety, or acceptance criteria.
If any commit introduces substantive runtime behavior, a security or data boundary change, a
migration, or an independently reviewable deployment change, use the canonical review behavior
for that change instead of classifying it as mechanical.

# Durable review proof across session boundaries

A completed Review Batch remains valid across a continuation, retry, max-turn restart, or worker
change only when the durable workpad records the completed batch, its required review coverage,
all findings and dispositions, the exact comparison base, and an exact content fingerprint of the
reviewed code-bearing tree. The fingerprint must include committed, staged, unstaged, untracked,
generated, and lockfile content. On resume, verify that the recorded comparison base, tree
fingerprint, and required review scope still match. When they match and no finding remains
unresolved, reuse that exact Review Batch; do not launch another panel solely because the session
boundary changed.

Fail closed and run the canonical required review again when the evidence or fingerprint is
missing or ambiguous, the comparison base or acceptance or review scope changed, a finding is
unresolved or newly applicable, or any code-bearing content changed after review. Workpad, logs,
comments, and other evidence-only updates do not invalidate an otherwise exact match. Reusing a
Review Batch never satisfies or replaces the primary agent's authoritative final gate, required
CI, deployment checks, or fresh remote proof.

# Bound work when the reported failure does not reproduce

When the issue's exact pinned reproduction succeeds or the reported failure otherwise does not
reproduce, record the exact command, revision, environment, and result in the durable workpad
before changing code. Then make an explicit scope decision: either complete the issue with
evidence when its acceptance criteria are already satisfied, or implement the smallest
deterministic regression or correction still required by those criteria.

Do not turn a stale or non-reproducing report into a new repository-wide enforcement framework,
generator, or policy unless an acceptance criterion requires that wider surface or the narrow
path is proven insufficient. Record that proof and the bounded expansion before implementation.
Failure to reproduce does not waive any remaining acceptance criterion, required review, final
gate, CI, deployment check, or workflow-owned transition.

# Freeze a published head while its evidence is pending

After the accepted implementation is committed and pushed and exact-head checks or review are in
progress, keep the code-bearing tree fixed. Observe and classify the published evidence before
editing again. Do not add speculative cleanup, helper extraction, extra tests, generated changes,
or other unrequested remediation merely because the issue remains active or a new Symphony turn
begins.

Change the published tree only in response to a concrete classified check failure, review finding,
newly discovered acceptance gap, stale-base repair, or other recorded evidence that the current
head cannot satisfy the issue. Record that trigger and its mapping before editing, then
produce one bounded remediation batch and rerun the review and gates invalidated by that batch.
This freeze does not prevent required feedback fixes, current-main synchronization, or
workflow-owned transitions.

# Do not wait for a CI job that is not part of the current gate

Before waiting for a named pull-request job, inspect the checked workflow, its change classifier,
the repository ruleset, and the issue's acceptance criteria. If that job is intentionally not
scheduled for the pull request and the acceptance criteria assign its authoritative proof to a
post-merge or containing-main run, record the absent PR job and proceed once every actual
pre-merge gate is satisfied. Do not retry, edit code, or hold a review-ready issue for a job that
the repository will not create.

Fail closed when a ruleset-required or acceptance-required pre-merge job is unexpectedly absent,
skipped, stale, or ambiguous. This rule only distinguishes the designed proof stage; it never
waives the required containing-main, deployment, or other later evidence.

# Serialize gates that share repository-visible temporary state

Before running independent final gates concurrently, verify that they are hermetic with respect to
the checkout and every workspace path scanned by package, graph, generator, lockfile, or inventory
discovery. Run gates sequentially when either gate creates, removes, or mutates repository-visible
temporary proof workspaces, generated files, lockfiles, caches, or discovery inputs that the other
gate can observe. A transient failure caused by one gate observing another gate's temporary state
is orchestration interference, not a product finding; wait for cleanup and rerun the affected gates
sequentially without expanding implementation scope.

Prefer placing temporary proof workspaces outside the scanned repository graph when the canonical
test supports it. Concurrency is still allowed for gates whose inputs and outputs are proven
isolated. Record the isolation decision when parallel execution materially affects the completion
timeline.

# Bound long-running command output

Keep complete validation evidence without feeding the full output of a verbose build, test, audit,
or deployment command back into the model on every wait. Before starting a command that may run
longer than one tool interval or emit more than 200 lines, create a task-scoped log below the path
returned by `git rev-parse --git-path symphony-logs`. Run the command with stdout and stderr
redirected to that log while preserving its exact exit status.

While it runs, report only a compact heartbeat containing the command identity, elapsed time, and
current log byte or line count. Do not repeatedly stream or reread the accumulated log. On success,
return the exit status and a concise result summary. On failure, return the exit status, the log
path, the exact matched failure signal, and at most the final 200 relevant lines; inspect an
additional bounded slice only when that tail cannot classify the failure.

The durable log is evidence, not disposable console noise: retain it through the turn and record
the exact command, result, and relevant failure or success signal in the workpad. Output bounding
must never hide a nonzero exit, weaken a gate, omit a required test, or replace required uploaded
artifacts. Use direct output for short, already-quiet commands.

# Bound provider evidence probes

Run repository-owned executable validation before optional provider-log inspection. A missing,
failed, or inaccessible provider receipt remains a fail-closed acceptance blocker, but it must not
suppress or delay the independent code gate for the exact pull-request head.

Wrap provider CLIs and remote log streams in a non-interactive timeout of at most 90 seconds and
write their bounded output to the task-scoped durable log. On timeout, terminate the entire probe
process group. Record the provider evidence as unavailable with the exact command and
exit status, and continue every independent local or hosted validation. Never leave `vercel
inspect --logs`, a deployment log stream, or an equivalent provider probe running in the
background across reasoning, continuation, or defer.

Skipped hosted CI on a draft pull request is not executable validation. Keep the pull request
draft and unmerged. Inspect the skipped job's checked workflow definition and reproduce its actual
repository command, required environment, and arguments locally on the exact published head; a
different broader gate is not a substitute unless the workflow itself invokes that gate with the
same environment and arguments. Record the workflow job, command, head SHA, exit status, and
concise result in durable issue or pull-request evidence.
Do not make a draft ready merely to cause CI to run.

# Dependency-upgrade scope budget

Before a dependency upgrade expands into replacing a provider-facing development tool, record an
explicit scope-budget decision in the durable workpad. Choose either:

1. stay within the ticket's bounded exception, preserve the provider tool, and record the exact
   remaining advisory or transitive constraint with the evidence required by the ticket; or
2. expand into tool replacement only when the issue's acceptance criteria require it or the
   replacement is demonstrably necessary to complete them, recording the justification, migration
   surface, validation plan, and remaining budget first.

Do not silently turn a package update into a provider-tool migration. A ticket that explicitly
allows a bounded exception authorizes the first choice; it does not by itself authorize broader
replacement work. Preserve canonical review, compatibility, credential isolation, deployment, and
final-gate requirements whichever choice is made.

# Fresh remote proof in Merging

On every entry into `Merging`, refresh the pull request target before making any current-main,
staleness, or ancestry claim. Run an explicit authenticated fetch of the target branch from its
remote, update the corresponding remote-tracking ref, and compare that freshly fetched ref with the
pull request head. Do not rely on a workspace's pre-existing `origin/main`, a bootstrap snapshot, a
cached pull-request base OID, or a prior turn's workpad claim.

If the fresh target is not an ancestor of the pull request head, keep the issue in `Merging` and
rebase the branch onto that target. Once the rebase repair is committed, the worktree is clean,
the fresh target is an ancestor of the repaired head, and focused conflict-surface tests pass,
publish that exact head immediately with `--force-with-lease`. Start exact-head hosted CI, then
run the long authoritative local gate and the one consolidated review panel while hosted CI is
in flight. Do not hold a publishable rebase repair behind those long gates.

If a later local gate, review finding, or hosted check identifies a concrete defect,
treat the earlier hosted run as superseded: make one bounded repair batch, rerun the invalidated
focused
proof, commit, republish with `--force-with-lease`, and restart exact-head evidence collection.
Never merge until the final remote head is clean and both its required hosted checks and all
required local gate and consolidated-review evidence are green.
Staleness alone never returns an authorized issue to `Human Review`.
Record the exact fetched target SHA and the ancestry result, published
head, and any superseded run in the durable workpad before landing.

# Retain Merging through post-merge verification

After the attached pull request is merged, keep the issue in `Merging` while required
containing-main CI, deployment, or other post-merge proof is pending. A merged or closed pull
request is evidence that landing occurred; it is not, by itself, evidence that implementation
restarted or needs another review. Never move the issue from `Merging` to `In Progress`, `Human
Review`, or `Rework` solely because the pull request is merged or closed, or because its required
containing-main proof has not completed yet.

Resolve and freeze the issue's containing-main revision from the attached pull request's merge
commit (or, when the repository creates no merge commit, the first target-branch revision that
contains the landed head). Required post-merge gates belong to that frozen revision. Once its
required gates are terminal and successful, do not advance the proof target to a newer
target-branch head or wait for an unrelated later run; subsequent commits cannot invalidate the
issue's already successful landing proof. Record both the frozen revision and its gate URLs in the
durable workpad.

When every required post-merge gate succeeds, transition the issue directly from `Merging` to
`Done` using the canonical workflow-owned transition. When a required post-merge gate fails, keep
the issue in `Merging` and follow the canonical failure-repair and completion semantics for that
concrete failure; do not use the merged or closed pull-request state or a merely pending gate as a
failure signal. This rule changes neither the required gates nor their fail-closed interpretation.

The canonical guardrail that says an issue with an attached merged pull request should move to
`Done` is only a routing shorthand into this post-merge reconciliation. It never authorizes the
transition before every required containing-main CI, deployment, and other post-merge gate has a
terminal successful result. Pending, missing, stale, or ambiguous evidence is not success.

# Require terminal evidence before a successor repair

Do not open, reopen, or move an issue into an active successor-repair lane from a local failure,
another issue's integration failure, or any other cross-issue observation while the authoritative
containing-main gate for the alleged owning change is still pending. Record the observation on the
currently active issue and wait outside the model for the containing-main gate to become terminal.

Only a terminal authoritative failure may create or reactivate a successor repair, and its workpad
must identify the exact containing-main revision, gate URL, failed job, and failure signal. A
terminal successful containing-main gate disproves the proposed successor lane unless the
successor issue independently reproduces its own acceptance failure on that same containing-main
revision. Do not consume a worker rerunning implementation tests merely to confirm a pending
cross-issue suspicion.

# Recover issues bounced after merge

At the start of any active turn, if an `In Progress` or `Rework` issue has exactly one
unambiguous attached pull request and that pull request is already merged, route directly to
post-merge reconciliation before reproducing, planning, editing, reviewing, or running
implementation tests. Verify the containing-main revision and every required post-merge gate.

When those gates are already terminal and successful, update the durable workpad with their exact
evidence and transition the issue directly to `Done` using the canonical workflow-owned
transition. Do not create a successor branch, rerun the implementation test suite, or return the
issue to `Merging` first. If any required gate is pending, keep the issue in its current active
state and wait outside the model. If a gate is terminal and failed, follow the canonical
failure-repair semantics for that exact failure.
