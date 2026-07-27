# DOKS throughput policy

This deployment overlay augments the canonical repository workflow. It does not replace its
requirements, status model, review gates, or safety rules.

## External-wait checkpoint

When all actionable repository work is complete and progress depends only on an asynchronous
external event such as GitHub checks, deployment verification, or human review:

1. Query the external system once and record the exact identity being awaited in the workpad,
   including the PR and head SHA plus the check run or deployment ID and its current status.
2. Persist every local change, workpad update, and validation result needed by a continuation.
3. End the invocation cleanly without sleeping, repeatedly polling, changing the Linear state, or
   treating the wait as a failure. Symphony will retain the active issue and schedule its
   continuation without holding the authenticated worker.
4. On continuation, re-query the recorded identity once. Resume the matching gate when it is
   terminal; otherwise checkpoint and yield cleanly again.

Do not checkpoint while an actionable diff, merge conflict, reviewer comment, deterministic
failure, or other repository task remains.

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
