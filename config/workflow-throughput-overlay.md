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
