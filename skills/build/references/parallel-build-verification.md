# Parallel Build (Path B) — Verification Record

How the Build phase's parallel execution was verified. Path B = one full headless
`claude --print` session per task, each in a git worktree; OS-level concurrency.

## Architecture facts (doc-confirmed, code.claude.com/docs)

- A `claude -p` worker is a FULL session, not an Agent-tool subagent. It dodges the
  subagent skill-preload bug (#25834) and cross-spawn rules degradation (#49106).
- PreToolUse hooks fire in `-p` mode (only PermissionRequest does not).
- Settings/plugin discovery walks up from cwd; `CLAUDE_PROJECT_DIR` overrides it.
- Plugin hooks fire when the plugin is enabled; enablement is read from discovered
  settings → `--settings <project>/.claude/settings.json` merges it in for an
  out-of-tree worktree cwd.
- `claude -p --agent <plugin:agent>` loads the agent's system prompt + model.
- Headless retry: `--output-format json | jq .session_id` → `--resume <id>`.

## Real-run verification (actual `claude`, not fakes)

Run via `--plugin-dir <repo>` to load the (uninstalled-in-dev) plugin.

1. **Persona load (item 1)** — `claude -p --plugin-dir … --agent claudehut:claudehut-builder`
   resolved and self-identified as **"ClaudeHut Builder"**. The agent's system-prompt
   BODY carries the full RED→GREEN→REFACTOR + Gates/Guardrails, so TDD steering does
   NOT depend on skill preload.
   - Caveat: the model reported preloaded `skills:` as "none". Whether `skills:`
     frontmatter preload takes effect under `--print` is UNCONFIRMED (could be a model
     introspection limit, or a real non-load). Mitigation: TDD essentials are also
     injected via `--append-system-prompt`, and the persona body is authoritative.

2. **Hook firing + enforcement (item 3)** — in real `-p --plugin-dir` sessions at
   phase=build, an off-plan Write was DENIED (`permission_denials` populated, file
   not created, hook denial text surfaced verbatim). Both gates confirmed in real
   headless runs: the reuse-scan freshness gate, and — with `CLAUDEHUT_WORKER=1`
   (reuse-scan skipped) — the surgical-scope gate ("file … not in current plan").
   Plugin hooks fire headless and enforce.

3. **Stub compile-retry (item 2)** — mechanical; smoke-verified (single-compile loop,
   resume on failure, loud fail on empty session_id).

## Worker hook-stack guard

A worker is a full session, so the whole hook stack fires. Anything that can `deny`
or block a non-interactive worker that cannot satisfy it must early-exit under
`CLAUDEHUT_WORKER=1`:

- `prompt-router.sh` skip-phrase block — bypassed (user intent text could contain a
  skip-phrase and block every worker).
- `stop.sh` learn-phase block — bypassed (defensive; workers stay at phase=build).
- `pre-tool.sh` reuse-scan freshness gate — bypassed. A worker's RED step writes a
  NEW `*Test.java` (scaffold writes no tests), and a headless worker can't run
  `/reuse-scan` to clear a stale gate → would hang. The reuse decision was already
  made at plan time. **The surgical-scope gate is NOT bypassed** — workers are still
  denied off-plan writes (verified in a real run).

`CLAUDEHUT_SCAFFOLD=1` (stub session only) bypasses both scope AND reuse-scan, since
it writes the whole-feature skeleton including files no single task owns.

## Deterministic backstop

The per-group compile+test gate runs in the main repo (normal tooling) after each
group merges. It — not the worker scope-check — is the load-bearing enforcement
against semantic merge breaks. Worker hooks are defense-in-depth.

## Residual (one real run still recommended at scale)

The real runs above used a contained empty/synthetic project. A full end-to-end on a
real Gradle/Maven project (stub scaffold that actually compiles → parallel group →
gate green) is the remaining at-scale confidence check; the orchestration plumbing is
smoke-verified across happy/gitignored/failure paths.
