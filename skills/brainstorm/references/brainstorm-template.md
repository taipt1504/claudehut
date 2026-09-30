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
<!-- ch:schema kind=brainstorm total=600
1. Frame          | req=full
2. Options        | req=full
3. Premortem      | req=full
4. Recommendation | req=full
Changelog         | req=-
-->
<!-- ch:budgets final after evals/doclint-replay.sh on 613 v0.11 artifacts (2026-09-30, 06 §10); c caps are bytes, no vi factor -->
<!-- Optional on the full route: only when two or more workable mechanisms differ in cost or risk and Discover
     did not settle the choice. The brainstormer returns the data; the main thread copies from the
     "# Brainstorm" line down to tasks/NNNN-slug/brainstorm.md. The recommendation becomes a D-n row in the
     spec's section 6. Revision: edit in place, rev +1, and add "## Changelog" last with one line per rev. -->
# Brainstorm: Rate-limit order creation
> id: 0001-order-rate-limit · route: full · rev: 1

## 1. Frame <!-- the question in one sentence; owner constraints; 3–5 weighted criteria locked before options; one line on where this departs from Discover -->
Question: how do we cap order requests per client without a new runtime dependency?
Constraint (owner): no new infrastructure this sprint.

| Criterion | Weight |
|---|---|
| Correctness under burst | .40 |
| Footprint | .35 |
| Operability | .25 |

Discover: agrees with the scan (`adopt` Resilience4j).

## 2. Options <!-- 2–4 rows, each a different mechanism (two libraries for one mechanism are one option); #0 = adopt or extend the reuse-scan candidate -->
| # | Mechanism | Score | Pros | Cons | Risk |
|---|---|---|---|---|---|
| 0 | Adopt Resilience4j RateLimiter per client | 0.82 | Already configured; no new service | Per-instance counters | Low |
| 1 | Shared Redis counter | 0.61 | Cluster-wide limit | New dependency and failure mode | Medium |

## 3. Premortem <!-- chosen option: up to 3 lines of "it failed because …" with a mitigation; runner-up: 1 line -->
- #0 failed because a scaled-out deployment admitted N×10 per minute → accepted; revisit past 4 instances.
- #1 (runner-up) failed because Redis latency added to every order call.

## 4. Recommendation <!-- one sentence; it becomes D-n in the spec -->
Adopt option 0: it meets the burst criterion with no new dependency, which option 1 cannot.
