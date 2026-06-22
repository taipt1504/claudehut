# Reuse-scan template (copy per task → `.claude/claudehut/tasks/NNNN-<slug>/reuse-scan.md`)

<!-- Summary-first (reviewers read top-down — Rust RFC / Stripe pattern): the table IS the artifact;
     evidence sections exist only where the table alone can't justify the decision. Budget: ≤400 words
     total. The measured anti-pattern this replaces: 7 dimensions × (Searched + FOUND + DECISION +
     narrative paragraph) = 1,178 words of which ~60% repeated the table. -->

```markdown
# Reuse Scan: <task title>

> task: NNNN-<slug> · date: YYYY-MM-DD

## Summary
<!-- Decision ladder, stop at first fit: drop (YAGNI, rung 0) | framework (stdlib/Spring/installed dep,
     rungs 1-3) | adopt | extend (project reuse, rung 4) | new (rung 5, justified). "Existing asset" =
     the framework feature + dep for `framework` rows, the file:line for adopt/extend, "none" only for `new`. -->
| Dimension | Existing asset | Decision | Effort |
|-----------|----------------|----------|--------|
| <e.g. speculative cache> | not needed for this task | drop | - |
| <e.g. retries> | Resilience4j `@Retry` (build.gradle) | framework | S |
| <e.g. idempotency> | `RequestKeyFilter` — `src/.../RequestKeyFilter.java:34` | extend | S |
| <e.g. reaper job> | none | new — <≤10-word justification> | M |

## Evidence
<!-- ONE section per dimension whose Decision a reader could reasonably question — typically the
     "new" rows, contested "extend" rows, and "drop" rows. Obvious rows get NO section. No "Searched:"
     restating the dimension name; no narrative paragraph repeating the table row. -->
### <Dimension>
Searched: <terms / classpath dep> → found `file:line` or framework feature | nothing relevant.
Decision: drop/framework/adopt/extend/new — <one line: the deciding fact>.

## Recommendation
<ONE sentence: reuse X, extend Y, build Z new.>
```
