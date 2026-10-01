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
<!-- ch:schema kind=task total.light=600
1. Approach | req=light | budget=80
2. Tasks    | req=light | cells=Goal:12w,Test first:60c
Changelog   | req=-
-->
<!-- ch:budgets final after evals/doclint-replay.sh on 613 v0.11 artifacts (2026-09-30, 06 §10); c caps are bytes, no vi factor -->
<!-- task.md = the light-route plan: one obvious approach, no spec. Copy from the "# Task" line down to
     tasks/NNNN-slug/task.md. Header keys: profile feature|bugfix|migration · status draft|approved.
     Revision: edit in place, rev +1, and add "## Changelog" last with one line per rev. -->
# Task: Cache the partner token in Redis
> id: 0002-partner-token-cache · route: light · profile: feature · rev: 1 · status: draft

## 1. Approach <!-- 80 words; the one obvious way, its reuse anchor, what stays unchanged -->
`PartnerTokenService` reads the token from Redis key `partner:jwt:token` and fetches a new one only on a miss,
storing it with the TTL the partner returns. Reuse anchor: the existing `StringRedisTemplate` bean. No lock;
callers and the token response are unchanged.

## 2. Tasks <!-- one table; Files stays the 3rd column; Test first = ClassName#method (60 bytes) -->
| ID | Goal | Files | Test first | Verify | Depends |
|---|---|---|---|---|---|
| T-001 | Serve the token from Redis on a hit | src/main/java/app/partner/PartnerTokenService.java, src/test/java/app/partner/PartnerTokenServiceTest.java | PartnerTokenServiceTest#returnsCachedToken | `./gradlew test --tests PartnerTokenServiceTest` | — |
| T-002 | Fetch and cache with the partner TTL on a miss | src/main/java/app/partner/PartnerTokenService.java, src/test/java/app/partner/PartnerTokenServiceTest.java | PartnerTokenServiceTest#cachesWithPartnerTtl | `./gradlew test --tests PartnerTokenServiceTest` | T-001 |
