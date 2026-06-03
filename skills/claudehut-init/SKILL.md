---
name: claudehut-init
description: Use once per project before starting work (or when ClaudeHut reports no codebase index) to bootstrap ClaudeHut for a Java/Spring repository - detects the stack, generates the project memory + index + path-scoped rules, and wires the always-load @import slice. Invoked as /claudehut:init. Idempotent.
allowed-tools: Read Write Grep Glob Bash
---

# ClaudeHut Init (Bootstrap prerequisite)

Bootstrap is a **deterministic script**, not a hand-generation task. Run it; it writes the canonical project
plane + stack-gated rules + the `@import` slice with zero guesswork. Then optionally enrich the seeded stubs.
**Do NOT** hand-write these files or emit a JSON analysis instead — the script is the source of the writes.

## 1. Run the generator (REQUIRED — this writes everything)

!`"${CLAUDE_PLUGIN_ROOT}/bin/claudehut-init" "${CLAUDE_PROJECT_DIR}"`

It detects the stack from the build files and writes, under `${CLAUDE_PROJECT_DIR}/.claude/claudehut/`:
`MEMORY.md`, `PROJECT.md`, `LANGUAGE.md`, `architecture.md`, `reuse-index.json`, `learnings.jsonl`, `state/` —
plus the **stack-gated** rule tree under `.claude/rules/`, and appends the always-load `@import` slice to
`CLAUDE.md`. Idempotent: it skips existing plugin-owned files (pass `--refresh` to regenerate) and **never**
clobbers `learnings.jsonl`. If the `claude` CLI is absent when this skill runs, invoke the same binary via Bash.

## 2. Verify (REQUIRED)

!`ls "${CLAUDE_PROJECT_DIR}/.claude/claudehut/"`

`MEMORY.md`, `PROJECT.md`, `LANGUAGE.md`, `architecture.md`, and `reuse-index.json` must all be present. If the
script printed an error or any file is missing, fix the cause and re-run — **init is not complete until all five
exist** (P3: this is the binding prerequisite for project-adaptive memory and cross-session learning).

## 3. Enrich the seeded stubs (best-effort — raises quality, not required for correctness)

The script seeds judgment fields as `TBD — refine`. Improve them by reading the code (keep edits **under** the
provenance line — re-`init` treats them as authoritative and won't overwrite them):

- `architecture.md` / `PROJECT.md`: fill dependency direction, transaction strategy, error mapping, messaging topology.
- `reuse-index.json` `components[]`: catalog existing `@Service`/`@RestController`/`@Repository`/`@Component`
  classes (id, kind, `path`, purpose, tags) so the Brainstorm reuse-scan can find them.
- `LANGUAGE.md`: refine the canonical term meanings to this project's real usage.

## 4. Suggest MCP servers (optional, opt-in — never auto-install)

ClaudeHut ships **no** active MCP config and connects **nothing** automatically. Read the catalog at
`${CLAUDE_PLUGIN_ROOT}/templates/mcp-recommendations.md` and, against the detected stack, present a
**"Recommended MCP servers for this project (optional)"** block the developer can copy-paste:

- **tech-stack bucket** — emit the `claude mcp add --scope project …` line for each server whose `detect-when`
  matches a detected dependency. These give the Review auditors live data; without them the auditors review statically.
- **memory bucket** — always offer the knowledge-graph memory MCP.
- **research bucket** — always offer the docs MCP (context7) for current library best-practice.

Tell the user to substitute their own connection string / token — **never** print or store real secrets, and do
**not** run these commands yourself (suggest, don't force).

Finish: "Bootstrapped. Commit `.claude/` (except `state/`) to share with the team."
