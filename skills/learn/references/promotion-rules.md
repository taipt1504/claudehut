# Promotion Rules

## Threshold

A learning is promoted from project tier (`<repo>/.claudehut/memory/learnings.jsonl`) to global tier (`~/.claude/claudehut/memory/patterns.jsonl`) when:

1. The `signature` (sha256 of normalized title + category) appears in N or more DISTINCT projects.
2. N defaults to 3 (configurable via `claudehut-config.json#memory.promotion_min_projects`).
3. User has opted in: `claudehut-config.json#memory.global_promotion_opt_in == true`. (Default: false.)

## Distinct project counting

Project identity = sha256(`git config --get remote.origin.url || git rev-parse --show-toplevel`).

`~/.claude/claudehut/memory/projects.json` maps signature → set of project hashes:

```json
{
  "<signature>": {
    "projects": ["<hash1>", "<hash2>", "<hash3>"],
    "first_seen": "<ts>",
    "last_seen": "<ts>",
    "hits": 7
  }
}
```

When `len(projects) >= threshold` AND opted in → promote.

## What gets promoted

The entry's content is copied to `~/.claude/claudehut/memory/patterns.jsonl`. Modifications during promotion:

- Add `promoted_at: <ts>` field.
- Strip `files_touched` (those paths don't make sense globally).
- Add `projects: [<count>]` (just the count, not the hashes — privacy).

## Decay

Global entries that haven't received a new hit in `memory.decay_days` (default 180) are marked `deprecated: true`. Not deleted — filtered from default load.

User can purge deprecated entries: `claudehut prune --days 180 --confirm`.

## What does NOT get promoted

- `anti-pattern` specific to one project's framework version
- `command` containing project-local paths
- `gotcha` tied to a private library
- Any entry where `files_touched` contains paths matching `**/internal/**` or `**/proprietary/**`

## Opt-out per entry

Add `noPromote: true` to an entry's content metadata to prevent promotion even if threshold met.
