# Reuse-Detection Flow

## Table of contents

- [Backend selection](#backend-selection)
- [Native invocation matrix](#native-invocation-matrix)
- [Ranking algorithm](#ranking-algorithm)
- [Output normalization](#output-normalization)

## Backend selection

Read `state/integrations.json` (refreshed at `SessionStart`):

```json
{
  "understand_anything": {"available": true|false, "graph_path": "..."},
  "graphify": {"available": true|false, "graph_path": "...", "global_registry": true|false}
}
```

ClaudeHut **does not** build proxy/wrapper agents. It detects the backend, then invokes the native plugin command directly and normalizes output.

## Native invocation matrix

| Available | Action |
|-----------|--------|
| `understand_anything: true` | Invoke `/understand-chat "<topic + nouns>"` to query knowledge graph, OR parse `.understand-anything/knowledge-graph.json` directly for node match. |
| `graphify: true` | Run `Bash: graphify query "<topic>"`. Add `graphify path "<A>" "<B>"` if exploring dependency. Add `graphify explain "<class>"` for deep dive. |
| `graphify.global_registry: true` | Add `Bash: graphify global query "<topic>"` for cross-project candidates. |
| Both | Invoke both in parallel, then merge by `path` (dedupe). |
| Neither | Fallback: grep + heuristic (see below). |

## Ranking algorithm

For candidates from any backend:

```
score = source_weight(source) * (
          token_overlap(candidate.name, nouns) * 0.5 +
          recency_decay(candidate.last_modified) * 0.3 +
          memory_hit_count(candidate.signature) * 0.2)
```

`source_weight`:

| Source | Weight |
|--------|--------|
| understand_anything | 1.0 |
| graphify | 0.9 |
| graphify_global | +0.2 bonus for cross-project hit |
| grep_heuristic | 0.7 |

## Output normalization

Each candidate normalized to:

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

Persist to `.claudehut/state/tasks/<task-id>/reuse-scan.json` with `timestamp`.

## Fallback grep + heuristic (MVP)

When no backend available:

1. Extract nouns from topic.
2. `grep -rn "class .*$noun" src/main/java/`.
3. `grep -rn "$noun" .claudehut/memory/index.md`.
4. Rank by overlap + git recency.
5. Keep top 5.
