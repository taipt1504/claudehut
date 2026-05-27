# learnings.jsonl Schema

## One entry per line

```json
{
  "id": "learn-2025-05-27-001",
  "ts": "2025-05-27T10:42:00Z",
  "session_id": "abc123",
  "task_id": "2025-05-27-add-user-endpoint",
  "category": "pattern",
  "title": "Use ServerWebExchange.getRequest().getHeaders() in WebFlux handler",
  "content": "Read X-Userinfo from headers via ServerWebExchange; do not inject HttpServletRequest (servlet API not available in WebFlux). Cache parsed user in Reactor Context for downstream operators.",
  "signature": "sha256:abc...",
  "files_touched": [
    "src/main/java/com/foo/user/UserController.java"
  ],
  "hits": 1,
  "tags": ["webflux", "security", "header", "context-propagation"]
}
```

## Field reference

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | `learn-<date>-<seq>` |
| `ts` | ISO 8601 | UTC timestamp when entry appended |
| `session_id` | string | Originating Claude Code session id (for traceability) |
| `task_id` | string | Originating task (matches `state/tasks/<task_id>/`) |
| `category` | enum | One of: `pattern`, `anti-pattern`, `decision`, `gotcha`, `command` |
| `title` | string | One-line, imperative or descriptive |
| `content` | string | 2–5 sentences, self-contained |
| `signature` | string | sha256 of `lower(title) + ":" + category` — used for cross-project promotion |
| `files_touched` | array<string> | Source paths involved |
| `hits` | int | Counter; +1 on each subsequent occurrence of same signature |
| `tags` | array<string> | 2–5 retrieval tags |

## Optional fields

| Field | When |
|-------|------|
| `noPromote` | true to prevent promotion |
| `deprecated` | true after decay |
| `replaces` | id of older entry this supersedes |
| `references` | array of URLs (docs cited) |

## Append-only rules

- Never edit an existing line in place.
- To "update" a learning: append a new entry with `replaces: <old-id>`.
- To "delete" a learning: append a tombstone entry with category=`tombstone`, content=`<old-id>`.

## Tooling

Read entries: `jq -s '.' learnings.jsonl`.

Find by category: `jq 'select(.category=="anti-pattern")' learnings.jsonl`.

Find by tag: `jq 'select(.tags | index("webflux"))' learnings.jsonl`.
