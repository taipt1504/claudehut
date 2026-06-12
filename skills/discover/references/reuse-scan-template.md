# Reuse-scan template (copy per task → `.claude/claudehut/tasks/NNNN-<slug>/reuse-scan.md`)

<!-- Summary-first (reviewers read top-down — Rust RFC / Stripe pattern): the table IS the artifact;
     evidence sections exist only where the table alone can't justify the decision. Budget: ≤400 words
     total. The measured anti-pattern this replaces: 7 dimensions × (Searched + FOUND + DECISION +
     narrative paragraph) = 1,178 words of which ~60% repeated the table. -->

```markdown
# Reuse Scan: <task title>

> task: NNNN-<slug> · date: YYYY-MM-DD

## Summary
| Dimension | Existing asset | Decision | Effort |
|-----------|----------------|----------|--------|
| <e.g. idempotency> | `RequestKeyFilter` — `src/.../RequestKeyFilter.java:34` | extend | S |
| <e.g. caching> | none | new — <≤10-word justification> | M |

## Evidence
<!-- ONE section per dimension whose Decision a reader could reasonably question — typically the
     "new" rows and contested "extend" rows. Obvious rows get NO section. No "Searched:" restating
     the dimension name; no narrative paragraph repeating the table row. -->
### <Dimension>
Searched: <terms> → found `file:line` | nothing relevant.
Decision: adopt/extend/new — <one line: the deciding fact>.

## Recommendation
<ONE sentence: reuse X, extend Y, build Z new.>
```
