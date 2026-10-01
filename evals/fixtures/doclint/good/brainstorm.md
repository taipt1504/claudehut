# Brainstorm: Refund ceiling mechanism
> id: 0001-refund-ceiling · route: full · rev: 1

## 1. Frame
How do we bound refunds? Owner constraint: payment rows stay append-only.

## 2. Options
| # | Mechanism | Score | Pros | Cons | Risk |
|---|---|---|---|---|---|
| 0 | derived SUM | 8 | no schema change | one extra query | low |
| 1 | stored counter | 6 | fast read | drift | medium |

## 3. Premortem
SUM is slow on hot payments; runner-up drifts.

## 4. Recommendation
Adopt the derived SUM (becomes D-1).
