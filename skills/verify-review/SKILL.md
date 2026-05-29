---
name: verify-review
description: Phase 5 of ClaudeHut workflow — run verify pipeline (build/tests/coverage/lint/static/security) via a gate-runner subagent, then the orchestrator fans out reviewer subagents in parallel, aggregates shards, and decides pass-or-refactor; bounded retry (max 3) then escalate. Use after Build phase completes. Triggers when phase=loop.
---

## Dispatch contract (read this FIRST)

This phase runs in **two sub-steps from the main thread**. Nested subagent dispatch is unsupported (a subagent cannot spawn subagents), so the reviewer fan-out is always **main-thread** — the verifier is only a gate-runner.

### Step 1 — Gate runner (verifier subagent)

```
Task(
  subagent_type = "claudehut-verifier",
  prompt        = <output of scripts/dispatch-prompt.sh "$ARGUMENTS">
)
```

Render the prompt by running `$CLAUDE_PLUGIN_ROOT/skills/verify-review/scripts/dispatch-prompt.sh "$ARGUMENTS"` and pass the stdout verbatim as the Task `prompt`. The verifier runs build/test/coverage/lint/static gates, writes the `verify` stanza to `.claudehut/findings/<task-id>-findings.json`, and returns a gate summary.

### Step 2 — Reviewer fan-out (main thread, only when all verify gates pass)

Read the gate summary. If a gate failed, skip to Step 3 (the zero-shard / verify-fail guard yields `fail`). When gates pass, dispatch the reviewer roster in **ONE message** (multiple Task invocations — they run concurrently in isolated contexts):

```
Task: claudehut-reviewer-security   (always)
Task: claudehut-reviewer-perf       (always)
Task: claudehut-reviewer-style      (always)
Task: claudehut-reviewer-db         (only if diff touches db/migration/, *Repository.java, *Entity.java, or pool config)
Task: claudehut-reviewer-reactive   (only if web_stack == webflux)
Task: claudehut-reviewer-mapping    (only if diff touches *Mapper.java/*Dto.java/*Request.java/*Response.java/*ObjectMapper*.java/*JsonConfig*.java)
```

Each reviewer writes its own shard at `.claudehut/findings/<task-id>/reviewer-<name>.json` via Bash before returning. Dispatching a reviewer whose condition does not apply is safe — it writes an empty `[]` shard.

### Step 3 — Aggregate + decide (main thread, always)

```bash
$CLAUDE_PLUGIN_ROOT/skills/verify-review/scripts/aggregate-findings.sh <task-id>
```

Then read the decision via `claudehut_findings_decision <task-id>` (state.sh). `pass` → phase advances to learn; `fail` → inject a refactor task (verifier's "Refactor injection format") or escalate per retry count.

**Red flags** (counter each, do not give in):

| Rationalization | Reality |
|---|---|
| "Tests pass — skip reviewers." | Reviewers run in Step 2; that IS the gate. **Dispatch them.** |
| "I'll review the diff myself." | Loop phase = independent eyes; main-thread self-review fails the gate. **Dispatch.** |
| "Let the verifier handle the reviewers." | The verifier is a gate-runner only; it cannot spawn subagents. Fan-out is YOUR job in Step 2. **Do not re-nest.** |

**Only exception**: user explicitly types `--inline` or "don't spawn a subagent". Then proceed inline and log the deviation in `.claudehut/findings/`.

---

# Verify-Review — Phase 5 (Loop)

Quality gate that may iterate. Each iteration either passes (→ Learn) or injects a refactor task back to Build.

## Quick start

1. **Verify stage** — Step 1 dispatch the `claudehut-verifier` gate-runner; it runs `scripts/run-verify-parallel.sh` and writes the `verify` stanza.
2. **Review stage** — Step 2 (main thread): dispatch the reviewer roster in ONE message; each writes a shard to `.claudehut/findings/<id>/reviewer-<name>.json`.
3. **Aggregate** — Step 3: `scripts/aggregate-findings.sh <task-id>` merges reviewer shards from `.claudehut/findings/<id>/reviewer-*.json` into `.claudehut/findings/<id>-findings.json` with totals + decision.
4. **Decide:**
   - verify pass AND 0 Critical AND 0 High → PASS. Advance to Learn.
   - any verify gate fail OR ≥ 1 Critical OR ≥ 1 High → FAIL. Inject refactor task. Retry++.
   - Retry == 3 → ESCALATE to user.

## Verify gates

Detailed gates + thresholds: `references/verify-gates.md`.

| Gate | Block-on |
|------|----------|
| Build | any compile error |
| Unit tests | fail/skip |
| Integration tests | fail |
| Coverage | line < threshold (config) |
| Lint (Spotless/Checkstyle) | error severity |
| Static (SpotBugs/PMD/SonarLint) | medium+ |
| OWASP dependency-check | High/Critical |

## Review subagents (parallel)

Detailed reviewer roster: `references/reviewer-dispatch.md`.

- `claudehut-reviewer-security`
- `claudehut-reviewer-perf`
- `claudehut-reviewer-db`
- `claudehut-reviewer-reactive` (skip if web_stack ≠ webflux)
- `claudehut-reviewer-style`
- `claudehut-reviewer-mapping` (skip if no MapStruct/Jackson involved)

Dispatched by the **orchestrator (main thread)** in ONE message with multiple Task invocations — never serialize, and never via the verifier (it cannot spawn subagents).

## Decision logic

Detailed retry/escalation: `references/retry-escalation.md`.

```
verify_pass  = all gates green
review_clean = critical == 0 AND high == 0
if verify_pass AND review_clean:
    advance to "learn"
else:
    retry++
    if retry < 3:
        inject refactor task into plan
        return to "build"
    else:
        escalate to user with full findings
```

**Route-aware (adaptive depth):** the `advance to "learn"` / `inject refactor
task into plan` steps assume the **full** profile. In the **quick** profile
there is no plan and no Learn phase, so:
- pass → the state machine advances straight to `done` (quick consolidates no
  learnings); just suggest `claudehut-finish`.
- fail (retry < cap) → there is no plan to inject into. Address the finding
  **inline** with TDD discipline, commit `refactor(loop): …` (the retry counter
  is git-derived, so the commit prefix is what matters), then re-invoke
  verify-review. Escalation at the cap is identical.

## Scripts

- `scripts/run-verify-parallel.sh` — invokes Gradle/Maven verify gates; emits gate JSON.
- `scripts/aggregate-findings.sh <task-id>` — merges reviewer shards (`.claudehut/findings/<id>/reviewer-*.json`) + the verify stanza into `.claudehut/findings/<id>-findings.json` with totals + decision (`high==0` rule; zero shards → fail).

## Assets

- `assets/templates/findings-report.md.tmpl` — human-readable findings summary.

## Exit criteria

- [ ] All verify gates green
- [ ] 0 Critical + 0 High findings
- [ ] findings.json persisted
- [ ] Phase advanced to `learn`
