# DOKS throughput policy

This deployment overlay augments the canonical repository workflow. It does not replace its
requirements, status model, review gates, or safety rules.

## External-wait checkpoint

When all actionable repository work is complete and progress depends only on an asynchronous
external event such as GitHub checks, deployment verification, or human review:

1. Query the external system once and record the exact identity being awaited in the workpad,
   including the PR and head SHA plus the check run or deployment ID and its current status.
2. Persist every local change, workpad update, and validation result needed by a continuation.
3. Call `symphony_merge_writer` with `{"action":"yield"}` and then end the turn without sleeping,
   repeatedly polling, changing the Linear state, or treating the wait as a failure. The explicit
   yield stops back-to-back Codex continuation, releases any writer lease and the authenticated
   worker, and schedules a later continuation for the still-active issue.
4. On continuation, re-query the recorded identity once. Resume the matching gate when it is
   terminal; otherwise checkpoint and yield cleanly again.

Do not checkpoint while an actionable diff, merge conflict, reviewer comment, deterministic
failure, or other repository task remains.

## Bounded Linear reads

Use the issue snapshot already supplied by Symphony and the durable workpad as the normal source
of issue context. Do not issue an unbounded Linear GraphQL query for issue history, comments,
attachments, relations, or workpad content. When an authoritative refresh is necessary, request
only the fields needed for the current decision, use a finite page size of at most 25, and paginate
only until that decision can be made. Summarize the result in the workpad; do not copy a complete
GraphQL response into the conversation.

On continuation, reuse the summary unless the relevant Linear field may have changed. A missing or
ambiguous bounded result may be refreshed with another bounded query, but must not be replaced by a
full-history query. This protects the agent transport from oversized tool responses while
preserving authoritative Linear verification and workflow-owned writes.

## Parallel merge preparation and final-writer lease

Merging preparation is parallel: synchronize the branch, resolve conflicts, address review,
validate, and observe external checks without holding the final-writer lease. Once every final
prerequisite is satisfied, call `symphony_merge_writer` with `{"action":"acquire"}`. If another
issue owns the lease, use the external-wait checkpoint.

After acquiring the lease, revalidate the exact PR head, current base, approval, and required
checks before executing the irreversible merge step. Call `symphony_merge_writer` with
`{"action":"release"}` immediately after landing. Release before continuing or yielding if any
prerequisite becomes non-terminal or actionable repair is needed. Process exit also releases the
lease, but explicit release is required.

## Exact-state validation evidence

Treat a successful local validation result as reusable evidence, not as a reason to rerun the same
commands on every continuation. The single workpad is the durable evidence cache.

Before running a local validation set, compute and record this identity:

- `head_sha`: the full commit SHA being validated (`git rev-parse HEAD`);
- `main_sha`: the full fetched default-branch SHA used as the comparison/merge base
  (`git rev-parse origin/main` after `git fetch origin main`);
- `config_digest`: SHA-256 of a canonical, newline-delimited manifest containing every command in
  the validation set, its relevant arguments/environment mode, and the contents or blob SHAs of
  configuration files that select or materially change those checks.

Record successful evidence in the workpad `Validation` section with the exact identity, commands,
terminal result, and observation time. Before rerunning a validation set, re-read that evidence and
recompute all three identity fields. Reuse it only when:

1. all three fields match exactly;
2. every required command has a recorded successful terminal result;
3. the working tree is clean, so no uncommitted input exists outside `head_sha`; and
4. no ticket requirement, review request, or documented repository policy explicitly requires a
   fresh execution.

If reusable, cite the matching evidence in the workpad and continue without rerunning those local
commands. Any changed head, fetched main, command set, environment mode, or relevant check
configuration invalidates the evidence. Missing, partial, ambiguous, or failed evidence is never
reusable.

This optimization applies only to redundant local validation. It never replaces required GitHub
checks, human review, deployment verification, exact-main verification after merge, or a targeted
rerun needed to prove a new fix. Query those authoritative external gates for the exact current SHA.

## Shared-gate repair classification

Use the `production-gate` label only for the single issue that owns a reproduced production or
deployment-gate failure blocking multiple otherwise ready issues. Use `main-ci` only for the
single issue that owns a reproduced deterministic protected-main CI failure with shared impact.
Require a concrete failure signature, proof of shared impact, and explicit repair acceptance
criteria. Reuse an existing active owner for the same signature instead of creating or labeling a
duplicate. Do not infer either label merely because an ordinary issue observes a failing check.

During normal Symphony workpad reconciliation, if the current issue is the explicit shared-gate
repair owner and satisfies these requirements, add its missing matching label through the workflow
before continuing. This includes an existing unlabeled owner discovered after classification was
introduced. When the workflow creates a new shared-gate repair owner, apply the matching label in
the same workflow-owned create/update sequence. Do not rely on an operator, monitor, or other
out-of-band Linear mutation to activate dispatch priority.

These labels are scheduler priority inputs within a state: `production-gate` ranks before
`main-ci`, and both rank before ordinary work. They never bypass required review, validation,
credential isolation, deployment safety, or serialized final merge ownership.
