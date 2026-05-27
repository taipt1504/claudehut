<!-- claudehut-managed-section -->
## ClaudeHut Plugin Active

@.claudehut/memory/conventions.md
@.claudehut/memory/stack-signals.md
@.claudehut/memory/learnings-recent.md

**Workflow** (6-phase, hook-enforced): Brainstorm → Spec → Plan → Build → Loop → Learn.

**Hard rules**:
- Phase derives from artifacts present + git branch. Do not bypass.
- Source edits (`src/`) only allowed in Build phase.
- New Java files require a fresh reuse-scan (< 10 min).
- TDD enforced: write a failing test before production code.
- One commit per plan task. Loop iterations use `refactor(loop):` prefix.

Per-glob coding/architecture/testing/security/performance/framework rules
live in `.claude/rules/` — copied from the plugin by `/claudehut:init`.
Claude auto-loads each rule when it reads a file matching the rule's
`paths:` frontmatter.

Workflow state lives in `.claudehut/{specs,plans,findings}/`.
<!-- /claudehut-managed-section -->
