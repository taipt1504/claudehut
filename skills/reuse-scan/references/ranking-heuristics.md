# Ranking Heuristics

## Composite score formula

```
score = source_weight × (
          token_overlap(name, nouns) × 0.5 +
          recency_decay(last_modified)  × 0.3 +
          memory_hit_count(signature)   × 0.2)
```

## Source weight table

| Source | Weight | Rationale |
|--------|--------|-----------|
| understand_anything | 1.00 | Richest semantic; layer-aware |
| graphify | 0.90 | Good semantic + community clustered |
| graphify_global | 0.90 + 0.20 bonus | Cross-project hit signals strong pattern |
| grep_heuristic | 0.70 | Lexical only |

## Sub-score functions

### token_overlap

Jaccard similarity over normalized tokens (lowercase, snake-split, stem):

```
tokens(name) = split(camelCase, snake_case, lowercase)
overlap = |tokens(name) ∩ tokens(nouns)| / |tokens(name) ∪ tokens(nouns)|
```

Range: 0.0 (no overlap) → 1.0 (identical).

### recency_decay

Exponential decay over days since `last_modified`:

```
recency = exp(-days / 90)
```

- Today: 1.0
- 30 days ago: 0.72
- 90 days ago: 0.37
- 365 days ago: 0.02

### memory_hit_count

Count of how many times this `signature` appears in `learnings.jsonl`:

```
hit_score = min(1.0, hits / 5)
```

Cap at 5 hits = 1.0.

## Tie-breaking

When two candidates have score within 0.05:

1. Prefer in-project (non-cross-project).
2. Prefer Service layer over Util.
3. Prefer more recently modified.
4. Prefer shorter path (closer to project root usually = core module).

## Threshold for "no good reuse"

If top candidate score < 0.30 → don't suggest reuse; greenlight new implementation.

This prevents spurious "consider reusing FooBarHelperUtil" for unrelated tasks.
