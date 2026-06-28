# Reuse-scan template (copy per task → `.claude/claudehut/tasks/NNNN-<slug>/reuse-scan.md`)

<!-- Summary-first (reviewers read top-down — Rust RFC / Stripe pattern): the table IS the artifact;
     evidence sections exist only where the table alone can't justify the decision. Budget: ≤450 words
     total. The measured anti-pattern this replaces: 7 dimensions × (Searched + FOUND + DECISION +
     narrative paragraph) = 1,178 words of which ~60% repeated the table.

     v0.7 (Issue 2): a reuse scan that only answers "does X exist?" is not enough — it must answer
     "does adopting X actually FIT this task, and what does adopting it IMPACT?". The Fit + Impact columns
     force that judgment (semantic, not signature-match). This is cognition, not grep: reason about whether
     the existing asset's contract serves THIS task, and the blast-radius of coupling to it. -->


```markdown
# Reuse Scan: <task title>

> task: NNNN-<slug> · date: YYYY-MM-DD

## Summary
<!-- Decision ladder, stop at first fit: drop (YAGNI, rung 0) | framework (stdlib/Spring/installed dep,
     rungs 1-3) | adopt | extend (project reuse, rung 4) | new (rung 5, justified). "Existing asset" =
     the framework feature + dep for `framework` rows, the file:line for adopt/extend, "none" only for `new`. -->
<!-- Fit (1-5): how well the asset's contract serves THIS task semantically — 5 = drop-in, 1 = forced
     misfit. Score adopt/extend/framework rows; drop/new = `-`. Impact: blast-radius of choosing this —
     callers touched, coupling introduced, regression risk. Keep each ≤8 words. -->
| Dimension | Existing asset | Decision | Fit | Impact | Effort |
|-----------|----------------|----------|-----|--------|--------|
| <e.g. speculative cache> | not needed for this task | drop | - | - | - |
| <e.g. retries> | Resilience4j `@Retry` (build.gradle) | framework | 5 | none — annotation only | S |
| <e.g. idempotency> | `RequestKeyFilter` — `src/.../RequestKeyFilter.java:34` | extend | 4 | adds 1 branch; 2 callers | S |
| <e.g. reaper job> | none | new — <≤10-word justification> | - | new class, isolated | M |

## Evidence
<!-- ONE section per dimension whose Decision a reader could reasonably question — typically the
     "new" rows, contested "extend"/"adopt" rows (Fit ≤3 or non-trivial Impact), and "drop" rows.
     Obvious rows get NO section. No "Searched:" restating the dimension name; no narrative paragraph. -->
### <Dimension>
Searched: <terms / classpath dep> → found `file:line` or framework feature | nothing relevant.
Fit: <why the asset does / doesn't semantically serve THIS task — the deciding fact, not the signature match>.
Impact: <what adopting it touches — callers, coupling, regression risk>.
Decision: drop/framework/adopt/extend/new — <one line>.

## Recommendation
<ONE sentence: reuse X, extend Y, build Z new.>
```
