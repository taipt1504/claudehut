# Reuse-scan template (copy per task → `.claude/claudehut/tasks/NNNN-<slug>/reuse-scan.md`)

<!-- Summary-first: the table is the artifact; an Evidence section exists only where the table alone
     cannot justify the decision, and does not repeat the table. Budget: ≤450 words total.
     The Fit and Impact columns record whether adopting an existing asset fits this task and what adopting
     it touches: a semantic judgment about the asset's contract and the blast radius of coupling to it,
     not a signature match. -->


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
