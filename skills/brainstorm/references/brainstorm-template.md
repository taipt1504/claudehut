# Brainstorm template (copy per task → `.claude/claudehut/tasks/NNNN-<slug>/brainstorm.md`)

<!-- The persisted deliberation. The brainstormer returns the data; the MAIN THREAD writes this file and
     records it with `claudehut-state set-brainstorm <path>`. The gate requires: ≥2 scored option rows
     (a header + ≥2 approaches), a Premortem heading, and a Recommendation. Spec §9 links it. -->

**Right-sizing — keep it tight:**
- `full` → all sections.
- `small`/`bugfix`/`refactor` reaching here (≥2 viable approaches) → §1, §3 options table, §5 Recommendation;
  a one-line premortem per finalist is enough. Never pad.

```markdown
# Brainstorm: <task title>

> id: NNNN-<slug> · tier: full|small · date: YYYY-MM-DD · loops: <n re-examine rounds, default 0>

## 1. Frame
- Problem in ONE sentence (restate, don't re-discover).
- Success criteria (3–5, weighted) — LOCKED before options, so scoring can't be reverse-engineered:
  | Criterion | Weight |
  |-----------|--------|
  | <e.g. correctness> | .30 |
  | <e.g. footprint>   | .20 |

## 2. Options (≥2 structurally distinct — different MECHANISM, not different library)
Option 0 = adopt/extend the reuse-scan candidate (always present when Discover found one). Score each
against the §1 criteria; eliminate dominated options (worse-or-equal on every axis).

| # | Approach | Score | Pros | Cons | Footprint | Risk |
|---|----------|-------|------|------|-----------|------|
| 0 | adopt/extend <existing> | <w-score> | … | … | small | … |
| A | <distinct mechanism> | <w-score> | … | … | … | … |
| B | <distinct mechanism> | <w-score> | … | … | … | … |
| W | <wildcard — rejected on instinct> | <w-score> | … | … | … | … |

## 3. Premortem (BOTH finalists — the runner-up's premortem often exposes the winner's fatal flaw)
- **<finalist 1>**: "six months on, this failed because …" → residual risk + mitigation.
- **<finalist 2>**: "… failed because …" → residual risk + mitigation.
<!-- If either premortem surfaces a HIGH/fatal risk, re-enter DIVERGE for one bounded round (cap 2) and
     increment `loops:` in the header. A loop that changes the recommendation is the point. -->

## 4. Recommendation
**<chosen option> — because <how it best satisfies the weighted criteria>.** One sentence on why NOT the
runner-up. Tie it back to §1, not to taste.

## 5. Enforcement set (code tasks — the 1% rule)
*If there is even a 1% chance a skill or rule applies, include it.* Drives which specialist reviewers Review
spawns, so completeness matters. (Recorded via `claudehut-state set-enforcement`.)
- skills: claudehut:implement, …
- rules: framework/jpa.md, security/owasp-top10.md, performance/n-plus-one.md, …
```
