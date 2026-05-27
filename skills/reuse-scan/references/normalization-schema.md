# Normalization Schema

## Single candidate

```json
{
  "path": "src/main/java/com/foo/user/UserService.java",
  "class": "UserService",
  "purpose_one_line": "CRUD + duplicate-check",
  "score": 0.92,
  "source": "ua",
  "layer": "Service",
  "cross_project": false,
  "last_modified": "2025-04-20T08:11:42Z",
  "matched_terms": ["user", "service", "duplicate"]
}
```

## File output

`.claudehut/state/tasks/<task-id>/reuse-scan.json`:

```json
{
  "task_id": "2025-05-27-add-user-endpoint",
  "topic": "add duplicate-check for user creation",
  "nouns": ["user", "duplicate", "check", "creation"],
  "timestamp": "2025-05-27T10:42:00Z",
  "integrations_used": ["understand_anything", "graphify"],
  "candidates": [
    {...},
    {...}
  ],
  "candidate_count": 5,
  "decision": "pending|reused|adapted|refused"
}
```

`decision` updated when user responds.

## Layer values

| Layer | Inference |
|-------|-----------|
| `Controller` | class name ends `Controller` |
| `Handler` | class name ends `Handler` (WebFlux) |
| `Service` | class name ends `Service` |
| `Repository` | class name ends `Repository` |
| `Mapper` | class name ends `Mapper` |
| `Config` | class name ends `Config` or `Configuration` |
| `Util` | class in `*.util.*` package |
| `Domain` | class in `*.domain.*` package |
| `Test` | path under `src/test/` |
| `Unknown` | none of above |

UA backend provides `layer` directly when available; for graphify/grep, inference based on naming + package.

## Source enum

- `ua` — Understand-Anything graph match
- `graphify` — Graphify local graph match
- `graphify_global` — Graphify cross-project registry match (sets `cross_project: true`)
- `grep` — fallback grep heuristic
