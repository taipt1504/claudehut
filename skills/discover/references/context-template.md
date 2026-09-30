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
<!-- ch:schema kind=context
Index brief  | req=full
Explorer map | req=full
-->
<!-- ch:budgets final after evals/doclint-replay.sh on 613 v0.11 artifacts (2026-09-30, 06 §10); c caps are bytes, no vi factor -->
<!-- context.md = the full route's evidence cache. The spec's Context section cites file:line or nodes from here
     instead of retelling. Discover writes it to tasks/NNNN-slug/context.md; doclint does not gate it. -->
# Context: order-rate-limit

## Index brief <!-- claudehut-index brief output, capped at 3000 B; until the index is built, the single line below -->
n/a — index not built

## Explorer map <!-- explorer output: entry points, key types and config as file:line; a fact the index lacked starts with index_miss: -->
- Entry: `OrderController#create` src/main/java/app/order/OrderController.java:42
- Config: `RateLimiterConfig` src/main/java/app/config/RateLimiterConfig.java:18 (Resilience4j registry)
- index_miss: `OrderController` has no rate limit today
