---
name: learn
description: Phase 6 of ClaudeHut workflow — extract patterns, anti-patterns, decisions, and reusable snippets from the completed task, persist as memory in `.claudehut/memory/learnings.jsonl`, update `index.md`, optionally promote to global tier when threshold met. Use after Verify-Review passes. Triggers when phase=learn.
---

# Learn — Phase 6

Convert one completed task into permanent memory that future sessions reuse.

## Quick start

1. Read git diff since branch base (`git log <base>..HEAD`).
2. Read approved design, contract, plan, findings report.
3. Run `scripts/learn-extract.sh` — proposes candidate entries.
4. Categorize each: pattern / anti-pattern / decision / gotcha / command.
5. Run `scripts/secret-scan.sh` on each candidate — reject leaks.
6. Append clean entries to `.claudehut/memory/learnings.jsonl`.
7. Run `scripts/reindex.sh` — regenerate `index.md`.
8. Run `scripts/promote.sh` — if threshold met AND `global_promotion_opt_in == true`, promote.

## Entry categories

| Category | Example |
|----------|---------|
| `pattern` | "Use ServerWebExchange to read userInfo header in WebFlux handler" |
| `anti-pattern` | "Do not inject HttpServletRequest in WebFlux handler" |
| `decision` | "Chose r2dbc-pool size = core×2 over default 10 for higher throughput" |
| `gotcha` | "Jackson @JsonTypeInfo defaultImpl breaks subtype whitelisting" |
| `command` | "./gradlew integrationTest -PdbBackend=postgres" |

Detailed extraction heuristics: `references/learning-categories.md`. Secret regex set: `references/secret-scan.md`. Promotion rules: `references/promotion-rules.md`. JSONL schema: `references/jsonl-schema.md`.

## Scripts

- `scripts/learn-extract.sh` — propose candidate learnings from diff + transcript.
- `scripts/secret-scan.sh <file>` — scan content for secret patterns.
- `scripts/promote.sh` — copy entry to `~/.claude/claudehut/memory/patterns.jsonl` if threshold met.
- `scripts/reindex.sh` — rebuild `.claudehut/memory/index.md` from learnings + source.

## Assets

- `assets/templates/learning-entry.json.tmpl` — single JSONL entry skeleton.

## Hard rules

- APPEND-ONLY. Never edit prior entries.
- Always secret-scan BEFORE write.
- Skip promotion unless user explicitly opted in (`global_promotion_opt_in: true`).
- Keep entries short (2–5 sentences); link to detailed code via `files_touched`.

## Exit criteria

- [ ] ≥ 1 new entry in `learnings.jsonl` (or explicit "no learnings" log)
- [ ] `index.md` regenerated
- [ ] 0 entries leaked secret regex
- [ ] Promotion check completed (may be no-op)
- [ ] Phase advanced to `done`
