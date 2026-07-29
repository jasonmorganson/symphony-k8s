# DOKS Linear-read guard

Use the issue snapshot supplied by Symphony and the durable workpad as the normal source of issue
context. When an authoritative Linear refresh is necessary, request only the fields needed for the
current decision, use a finite page size of at most 25, and stop pagination as soon as that
decision can be made.

Do not replace a missing or ambiguous bounded result with an unbounded query for issue history,
comments, attachments, relations, or workpad content. This read guard does not alter upstream
dispatch, Merging, landing, or Linear-transition behavior.

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

If the fresh target is not an ancestor of the pull request head, keep the issue in `Merging`, rebase
the branch onto that target, run the required validation, push the repaired head, and continue the
canonical land flow. Staleness alone never returns an authorized issue to `Human Review`. Record the
exact fetched target SHA and the ancestry result in the durable workpad before landing.
