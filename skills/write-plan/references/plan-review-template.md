<!-- ch:grammar (read by scripts/doclint.sh; an artifact copies neither this comment nor the schema block)
Schema block: a line that starts with the comment opener followed by "ch:schema kind=<kind>" and optional
  totals "total=N" or "total.<profile|route>=N"; then one row per line; then the comment terminator alone.
Row: "[N. ]Heading | attr | attr". The artifact heading is "## " + "[N. ]Heading", compared after trimming
  spaces; a trailing HTML comment on the heading line is ignored. Rows are listed in document order. A
  "## " heading with no row is rejected; "### " subheadings are free.
attr: req=<list> names the profiles/routes that require the heading ("-" = optional, no req = always
  required); a listed heading is always allowed. budget=N caps the words of the section body (advisory).
  diagram=required needs a mermaid block or a line "n/a — <reason>" in the section (blocking).
  cells=Col:Nw,Col:Nc caps each cell of the table column whose header is exactly Col; w = words,
  c = bytes (advisory).
Words: tokens holding a letter or digit, ignoring table pipes, separator rows, mermaid and HTML comments.
  At language=vi every word cap is multiplied by 1.4. Heading comments repeat the schema numbers for the
  writer; the schema block is the source. -->
<!-- ch:schema kind=plan-review total=400
Findings | cells=Gap:30w,Fix:30w
Notes    | req=-
-->
<!-- Written only by claudehut-plan-reviewer, which overwrites the file on each pass; the pass number lives in
     task state. Copy from the "# Plan review" line down to tasks/NNNN-slug/plan-review.md. The header's round is
     1 or 2. Exactly one verdict line, APPROVE or REVISE: REVISE when any finding is CRIT or HIGH. -->
# Plan review
> id: 0001-order-rate-limit · plan-rev: 1 · round: 1

Verdict: APPROVE

## Findings <!-- up to 10 rows (advisory: more is flagged, never refused); Sev is CRIT, HIGH or MED; Locus = plan section or T-id; an APPROVE may leave the table empty -->
| ID | Sev | Locus | Gap | Fix |
|---|---|---|---|---|
| F-1 | MED | T-003 | Test first does not check that a rejected call writes no order row (AC-001) | Assert the order count is unchanged in OrderControllerIT#returns429OverLimit |

## Notes <!-- optional; one line per observation outside the plan's scope -->
