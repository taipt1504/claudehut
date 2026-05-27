# Backend Matrix

## Detection signals

| Backend | Signal | Path |
|---------|--------|------|
| Understand-Anything | `<repo>/.understand-anything/knowledge-graph.json` exists | parse JSON directly |
| Understand-Anything plugin installed | `claude --list-plugins` includes `understand-anything` | invoke `/understand-chat`, `/understand-explain` |
| Graphify CLI | `command -v graphify` returns binary | `Bash: graphify ...` |
| Graphify graph built | `<repo>/graphify-out/graph.json` exists | parse JSON or `graphify query` |
| Graphify global registry | `graphify global list` succeeds | `graphify global query` for cross-project |

## Native commands per backend

### Understand-Anything

```bash
# Semantic query via skill
/understand-chat "Where is duplicate-check logic for users?"

# Deep dive single class
/understand-explain UserService

# Diff impact
/understand-diff
```

Or parse `knowledge-graph.json` directly:

```bash
jq '.nodes[] | select(.tags | contains(["user","service"]))' .understand-anything/knowledge-graph.json
```

### Graphify

```bash
# Semantic query
graphify query "duplicate-check user creation"

# Dependency path between two classes
graphify path "UserService" "UserRepository"

# Deep dive single node
graphify explain "UserService"

# Cross-project (org-wide)
graphify global query "tenant-isolation patterns"
```

## Invocation order

When BOTH backends available:

1. Spawn both in PARALLEL (single message, multiple Bash/Skill calls).
2. Wait for both to return.
3. Merge candidates by `path`.
4. Dedupe (same path → keep highest source weight + sum overlap from sources).
5. Re-rank.

Do NOT serialize — Graphify CLI is fast (< 1s for query); UA chat is slower (~5s). Parallel saves wall-clock.

## Skip conditions

| Skip if | Reason |
|---------|--------|
| Graph stale > 7d (UA) AND no auto-update hook | Warn + degrade to grep |
| Graphify graph not built (`graphify-out/` missing) | Warn + degrade to grep |
| Both backends fail (CLI error) | Fallback grep, log to state |

## Graceful degradation

ClaudeHut ALWAYS returns candidates — grep fallback guarantees output. The quality varies:

| Source | Quality | Speed |
|--------|---------|-------|
| ua + graphify | best (semantic + dependency-aware) | medium (5–10s) |
| ua only | very good (semantic) | medium (5s) |
| graphify only | good (clustered) | fast (1s) |
| grep fallback | acceptable (lexical) | fast (1s) |
