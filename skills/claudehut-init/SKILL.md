---
name: claudehut-init
description: Use once per project before starting work (or when ClaudeHut reports no codebase index) to bootstrap ClaudeHut for a Java/Spring repository - detects the stack, generates the project memory + index + path-scoped rules, and wires the always-load @import slice. Invoked as /claudehut:init. Idempotent.
allowed-tools: Read Write Grep Glob Bash
---

# ClaudeHut Init (Bootstrap prerequisite)

Bootstrap is a **deterministic script**, not a hand-generation task. Run it; it writes the canonical project
plane + stack-gated rules + the `@import` slice with zero guesswork. Then optionally enrich the seeded stubs.
**Do NOT** hand-write these files or emit a JSON analysis instead — the script is the source of the writes.

## 1. Generate the project plane + verify (REQUIRED)

**Call the `Bash` tool** to run the generator and list the result in one command — so you see the output and
handle any error directly (a tracked tool call, not shell auto-exec at skill-load):

```bash
"${CLAUDE_PLUGIN_ROOT}/bin/claudehut-init" "${CLAUDE_PROJECT_DIR}" && ls "${CLAUDE_PROJECT_DIR}/.claude/claudehut/"
```

The `SessionStart` hook already auto-runs the generator when the plane is absent, so this skill is the explicit
/ `--refresh` path — but run it here too so the listing confirms the plane.

It detects the stack from the build files and writes, under `${CLAUDE_PROJECT_DIR}/.claude/claudehut/`:
`MEMORY.md`, `PROJECT.md`, `LANGUAGE.md`, `architecture.md`, `reuse-index.json`, `learnings.jsonl`, `state/` —
plus the **stack-gated** rule tree under `.claude/rules/`, and appends the always-load `@import` slice to
`CLAUDE.md`. Idempotent: it skips existing plugin-owned files (pass `--refresh` to regenerate) and **never**
clobbers `learnings.jsonl`.

`MEMORY.md`, `PROJECT.md`, `LANGUAGE.md`, `architecture.md`, and `reuse-index.json` must all appear in the
listing. If any is missing, fix the error the command reported and re-run. **Init is not complete until all five
exist** (P3: the binding prerequisite for project-adaptive memory and cross-session learning).

## 2. Enrich the seeded stubs (best-effort — raises quality, not required for correctness)

The script seeds judgment fields as `TBD — refine`. Improve them by reading the code (keep edits **under** the
provenance line — re-`init` treats them as authoritative and won't overwrite them):

- `architecture.md` / `PROJECT.md`: fill dependency direction, transaction strategy, error mapping, messaging topology.
- `reuse-index.json` `components[]`: catalog existing `@Service`/`@RestController`/`@Repository`/`@Component`
  classes (id, kind, `path`, purpose, tags) so the Brainstorm reuse-scan can find them.
- `LANGUAGE.md`: refine the canonical term meanings to this project's real usage.

## 3. Suggest MCP servers (optional, opt-in — never auto-install)

ClaudeHut ships **no** active MCP config and connects **nothing** automatically. Read the catalog at
`${CLAUDE_PLUGIN_ROOT}/templates/mcp-recommendations.md` and match it against the detected stack to build the
candidate list:

- **tech-stack bucket** — each server whose `detect-when` matches a detected dependency (gives the Review
  auditors live data; without them they review statically).
- **memory bucket** — the knowledge-graph memory MCP.
- **research bucket** — the docs MCP (context7) for current library best-practice.

**In interactive use, call the `AskUserQuestion` tool** (multi-select) to let the developer pick which servers
to add — don't dump a copy-paste wall. Then emit a `claude mcp add --scope project …` line **only** for each
selected server. On a non-interactive run (`-p`) where `AskUserQuestion` is unavailable, fall back to printing
the recommended lines as a copy-paste block.

The developer substitutes their own connection string / token — **never** print or store real secrets, and do
**not** run these commands yourself (suggest, don't force).

Finish: "Bootstrapped. Commit `.claude/` (except `state/`) to share with the team."
