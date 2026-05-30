# Seeded-learnings retrieval eval (Phase 4)

Deterministic, free (no model calls). Proves the JIT ranker
(`skills/learn/scripts/retrieve-relevant.sh`) **discriminates by relevance, not
recency** against a seeded corpus.

```bash
evals/retrieval/run-retrieval-eval.sh        # also wired into tests/run-all.sh as L20
```

## How it's falsifiable (not a tautology)

- **Recency confound.** In `corpus.jsonl` the *relevant* learnings (L0x) carry the
  OLDEST timestamps; the distractors (D0x) are the NEWEST. So the old
  head-N-recency behavior (what `regenerate-recent.sh` dumped) scores **0%**
  precision here, while relevance retrieval scores 100%. The eval reports both.
- **Semantic ground truth.** `scenarios.json` `relevant` is authored from
  domain/intent (see each `why`), **independent of the scoring formula** — not
  "has the query's tag". Two anti-circular discriminators per the design:
  - `discriminator_in` — a relevant entry with **no shared tag**, retrievable only
    via package overlap (S_path). If retrieval were tag-equality, it'd be missed.
  - `discriminator_out` — a distractor with a **coincidentally-shared tag** (and a
    tombstone) that must be floored/filtered out.
- **No padding.** With only 2–3 relevant entries and K=5, the ranker must return
  **2–3, not 5** (the R>0.05 floor excludes the rest). Harder to fake than precision.

## Honest scope

A self-authored corpus proves the **mechanism discriminates by relevance signal**
(CI-locked, L20). It does **NOT** prove "Phase 4 improves real runs" — that needs
the opt-in **$ A/B**: a real claudehut run seeded with a corpus, measuring whether
the agent actually uses the surfaced learnings / converges cheaper. Scaffolded but
not auto-run:

```bash
CLAUDEHUT_EVAL_SEED_LEARNINGS=evals/retrieval/corpus.jsonl \
  evals/run.sh <task> claudehut        # seeds the corpus into the run's .claudehut/memory/
```

Whether real corpora actually have the relevant-but-old structure this eval
constructs is itself unproven — so the deterministic result is a necessary, not
sufficient, condition for the real-run win.
