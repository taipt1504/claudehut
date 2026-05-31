---
name: reuse-scan
description: Quet codebase tim impl tai su dung duoc truoc khi tao class moi (Java backend). Uu tien plugin da cai (Understand-Anything, Graphify) qua slash command native; fallback grep + heuristic. Auto-trigger o Brainstorm step 2 va PreToolUse(Write) cho file Java moi. Slash: /claudehut:reuse-scan <topic>.
---

# Reuse-Scan

ClaudeHut không tự build phân tích — detect + invoke native + normalize.

## Quick start

1. Run `scripts/detect-integrations.sh` — ghi `state/integrations.json`.
2. Based on integrations:
   - UA available → invoke `/understand-chat "<topic + nouns>"`.
   - Graphify available → `Bash: graphify query "<topic>"`.
   - Both → invoke parallel, merge by path.
   - Neither → `scripts/reuse-scan-grep.sh <topic>` (fallback).
3. `scripts/normalize-candidates.sh` → top-5 normalized list.
4. Write `state/tasks/<task-id>/reuse-scan.json` với timestamp.
5. Present candidates kèm `reuse | adapt | refuse` prompt.

## Backend matrix

Detailed: `references/backend-matrix.md`.

| Integration available | Native command invoked | Source weight |
|------------------------|------------------------|---------------|
| understand_anything | `/understand-chat "<topic>"` HOẶC parse `knowledge-graph.json` | 1.0 |
| graphify | `Bash: graphify query "<topic>"` | 0.9 |
| graphify global | `Bash: graphify global query "<topic>"` | 0.9 + 0.2 cross-project |
| neither | grep + heuristic | 0.7 |

## Output schema

Each candidate normalized:

```json
{
  "path": "src/main/java/com/x/UserService.java",
  "class": "UserService",
  "purpose_one_line": "CRUD + duplicate-check",
  "score": 0.92,
  "source": "ua|graphify|graphify_global|grep",
  "layer": "Service|Repository|Controller|Util",
  "cross_project": false
}
```

Ranking heuristics: `references/ranking-heuristics.md`. Schema details: `references/normalization-schema.md`.

## Scripts

- `scripts/detect-integrations.sh` — populate `state/integrations.json`.
- `scripts/reuse-scan-grep.sh <topic>` — fallback grep + heuristic.
- `scripts/normalize-candidates.sh` — merge + dedupe + rank.

## Hard rules

- NEVER build adapter/proxy. Invoke native plugin commands directly.
- ALWAYS write `state/tasks/<id>/reuse-scan.json` with timestamp.
- ALWAYS present candidates với `reuse | adapt | refuse` choice.
- Stale > 10 min → PreToolUse hook block new Java write until re-scan.

## Exit criteria

- [ ] `state/tasks/<id>/reuse-scan.json` exists with timestamp
- [ ] Top-5 normalized candidates rendered
- [ ] User chose `reuse | adapt | refuse` for each (or explicit "none applicable")
