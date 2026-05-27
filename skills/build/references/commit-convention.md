# Commit Convention

ClaudeHut uses [Conventional Commits](https://www.conventionalcommits.org/) for per-task commits.

## Format

```
<type>(<scope>): <imperative subject ≤ 50 chars>

<optional body — why, not what>

<optional footer — Refs, Breaking, etc>
```

## Types

| Type | Use when |
|------|----------|
| `feat` | New user-facing functionality |
| `fix` | Bug fix |
| `refactor` | Behavior unchanged, structure improved |
| `test` | Adding/changing tests only |
| `docs` | Documentation only |
| `chore` | Build, deps, tooling |
| `perf` | Performance improvement |
| `style` | Format-only (Spotless) |
| `migration` | Database migration |

## Scope

Short noun, lower-case. Matches the module/feature touched.

- `feat(user): add duplicate-check`
- `migration(user): add tenant_id column`
- `test(payment): cover Kafka idempotency path`

## Per-task pairing

Builder writes ONE commit per task. Test commit and impl commit can be:

- **Combined** (default): `feat(user): add duplicate-check + test`
- **Split** (when test scaffolding is large): two commits, test first.

## Anti-patterns

- "WIP" — never commit WIP from ClaudeHut.
- "Fix typo" alone — squash into the originating commit.
- "Various improvements" — too vague.
- Long subject + no body — explain WHY in body if non-obvious.
- Reference to issue tracker in subject — keep subject readable; put refs in footer (`Refs: PROJ-123`).

## Project override

If `.claudehut/memory/conventions.md` specifies a different style, follow project conventions over this default.
