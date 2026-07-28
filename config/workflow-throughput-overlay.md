# DOKS Linear-read guard

Use the issue snapshot supplied by Symphony and the durable workpad as the normal source of issue
context. When an authoritative Linear refresh is necessary, request only the fields needed for the
current decision, use a finite page size of at most 25, and stop pagination as soon as that
decision can be made.

Do not replace a missing or ambiguous bounded result with an unbounded query for issue history,
comments, attachments, relations, or workpad content. This read guard does not alter upstream
dispatch, review, Merging, landing, or Linear-transition behavior.
