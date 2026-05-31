# ClaudeHut — detailed usage guide

A practical, end-to-end guide to driving the plugin. For the overview/feature pitch see
the [README](../README.md); for design rationale see
[`ARCHITECTURE.md`](ARCHITECTURE.md) and [`UPGRADE_PLAN.md`](UPGRADE_PLAN.md).

---

## 1. Mental model

ClaudeHut makes Claude Code behave like a disciplined senior engineer for **Java/Spring
backend** work. Three ideas:

1. **Artifact-derived state.** There is no mutable "phase" file. The current phase is
   *derived* from which files exist on disk (+ the route). Delete an artifact → you fall
   back a phase. Commit one → you advance. No race conditions, no stuck state.
2. **Adaptive depth.** A triage step routes each task to `quick` (build + verify) or
   `full` (six phases). Ceremony is matched to risk — a typo doesn't pay a feature's tax,
   a migration can't skip the design gate.
3. **Hooks enforce, agents execute.** Claude Code hooks (`SessionStart`, `PreToolUse`, …)
   gate what's allowed; per-phase subagents do the work in isolated contexts.

**One branch = one task.** The git branch name is the task id (slashes → dashes). All
artifacts for a task live under `.claudehut/` keyed by that id.

---

## 2. Install + first run

```
> /plugin marketplace add taipt1504/claudehut
> /plugin install claudehut@claudehut
> /plugin enable claudehut
> /claudehut:init            # scaffold .claudehut/ + copy stack-matched rules into .claude/rules/
```

Prereqs: Claude Code ≥ 2.1.126, Java ≥ 17, `jq` ≥ 1.6, git. (Local-dev install:
`claude --plugin-dir /path/to/claudehut`.) See README → Installation for all paths.

`init` is idempotent and **stack-aware**: it reads `.claudehut/memory/stack-signals.md`
and copies only the rules matching your stack (e.g. `messaging=nats` → copies `nats.md`,
skips `kafka-consumer.md`). Re-run `/claudehut:init --refresh` after changing your stack;
your hand-edited rules are preserved (SHA256-tracked) unless you pass `--force`.

---

## 3. The workflow, phase by phase

Start any task on its own branch, then just describe the work:

```bash
git checkout -b feature/add-user-purchase-history
```
```
> Add an endpoint to fetch a user's purchase history.
```

### Phase 0.5 — Route (triage)

The first thing on a new task. `/claudehut:route` classifies intent and writes
`.claudehut/state/route-<task>.json`:

- **`quick`** — phases `[build, loop]`. Fires only on an explicit trivial signal (typo,
  off-by-one, rename, "tweak") AND no complexity/migration signal.
- **`full`** — phases `[brainstorm, spec, plan, build, loop, learn]`. The default for
  features, migrations, and anything ambiguous (conservative — never strips the design
  gate by accident).

You normally don't run `route` by hand; the orchestrator does it first. Inspect/override:
```bash
claudehut-state phase                          # => route (fresh) then the routed phase
cat .claudehut/state/route-*.json | jq .profile
```

### Phase 1 — Brainstorm *(full only)*

Scans the codebase + runs **reuse-scan** (don't reimplement what exists), then drafts
`.claudehut/specs/<task>-design.md` and resolves open decisions with you via questions.
`src/` edits are **blocked** until you approve the design. Output: an approved design doc.

### Phase 2 — Spec *(full only)*

Turns the design into a **binary behavioral contract** (Given/When/Then, API shape, edge
cases, NFRs) → `.claudehut/specs/<task>-contract.md`. Still no source edits.

### Phase 3 — Plan *(full only)*

Decomposes the contract into a **file-level task list** (2–5 min chunks, exact paths, RED
test commands, GREEN steps, DAG deps, risk callouts) → `.claudehut/plans/<task>-plan.md`,
with `- [ ]` checkboxes. Tasks can be grouped into **parallel groups** that run concurrently.

### Phase 4 — Build *(both routes)*

Now `src/` edits are allowed — **only for files in the current plan task** (surgical scope;
the hook denies out-of-scope writes). Strict TDD per task, enforced by `watch-test-fail.sh`:
RED (watch it fail for the *right* reason) → GREEN (minimum code) → REFACTOR → commit.
Parallel groups dispatch one builder per task, each in its **own git worktree**, merged back.

In `quick` mode there's no plan — the build does the fix inline under the same TDD discipline.

### Phase 5 — Loop (Verify ↔ Review ↔ Refactor) *(both routes)*

Runs the verify pipeline (build/tests/coverage/lint/static/security) via a gate-runner,
then fans out up to **6 read-only reviewer subagents** in parallel (security, perf, db,
reactive, style, mapping). Findings aggregate into `.claudehut/findings/<task>-findings.json`.
Decision rule: **0 Critical AND 0 High → pass**; else a refactor task is injected and Build
re-runs. Bounded to **3 retries** (`loop_max_retries`), then escalates to you.

### Phase 6 — Learn *(full only)*

Extracts patterns / anti-patterns / decisions / gotchas from the completed task, secret-scans
them, and appends to `.claudehut/memory/learnings.jsonl` (+ updates `index.md`). Signatures
recurring across ≥3 projects can be promoted to your global tier (opt-in).

### Done

```bash
claudehut-state phase          # => done
bin/claudehut-finish           # archive the task (or --abandon for a failed task)
```

---

## 4. Command reference

### `claudehut-state` (read-only inspection)
```bash
claudehut-state phase                 # derived phase
claudehut-state task-id               # task id (= branch, slashes→dashes)
claudehut-state branch                # git branch
claudehut-state retries               # loop retry count
claudehut-state stack <field>         # web|orm|db|messaging|mapper|serialization
claudehut-state config [key]          # read claudehut-config.json
claudehut-state docs                  # artifact paths for the current task
claudehut-state integrations          # UA/Graphify detection cache
```

### `claudehut-finish` (task closer)
```bash
bin/claudehut-finish                  # finish a passed task (runs update-usefulness, prunes logs)
bin/claudehut-finish --abandon        # close a FAILED task (downward usefulness pressure)
bin/claudehut-finish --cached --quiet # variants
```

### Slash skills (invoke in-session)
`/claudehut:init`, `/claudehut:route`, `/claudehut:reuse-scan <topic>`, `/claudehut:discover`
(status), `/claudehut:write-skill <name>`, plus the phase skills (`brainstorm`, `spec`,
`plan`, `build`, `verify-review`, `learn`) and domain skills (`spring-mvc`, `jpa-hibernate`,
`kafka-consumer`, `nats`, `rabbitmq`, `mapstruct`, `jackson`, `lombok`, `owasp-scan`, …).
The bootstrap rule: when work **clearly** falls in a skill's domain, invoke it — tangential
matches don't require it (file-specific guidance auto-loads via the rules layer).

---

## 5. Configuration — `.claudehut/claudehut-config.json`

`init` seeds this from the template. Every key:

```jsonc
{
  "phase": {
    "loop_max_retries": 3,              // refactor retries before escalating to you
    "allow_skip_phases": [],            // (advanced) phases the gate may skip
    "destructive_command_allowlist": [],// bash patterns to exempt from the destructive gate
    "stop_enforcement_enabled": false   // bounded Stop-hook escalation
  },
  "reuse_detection": {
    "stale_threshold_minutes": 10,      // a reuse-scan older than this is "stale" → re-scan
    "prefer_backends": ["understand_anything", "graphify"],
    "fallback_to_grep": true
  },
  "memory": {
    "promotion_min_projects": 3,        // signature must recur in N projects to promote global
    "decay_days": 180,
    "global_promotion_opt_in": false    // must be true to ever write your ~/.claude global tier
  },
  "coverage": { "line_threshold": 0.80, "branch_threshold": 0.70 },  // verify gate fails below
  "rules_override": {},
  "mcp_servers_enabled": ["context7", "memory", "sequential-thinking"],
  "agents": {
    "builder_model": "claude-sonnet-4-6",
    "reviewer_models": { "default": "claude-sonnet-4-6", "style": "claude-haiku-4-5", "mapping": "claude-haiku-4-5" }
  },
  "budget": {
    "max_worker_pool_usd": 8.00,        // cumulative cap across all build workers in a run (0 = unlimited)
    "max_worker_usd": 4.00,             // per-worker cap
    "worker_budget_floor": 0.50         // don't launch a worker under this
  }
}
```

Read any key live: `claudehut-state config budget` / `claudehut-state config phase.loop_max_retries`.

---

## 6. Memory & retrieval

- **Where:** `.claudehut/memory/learnings.jsonl` (append-only, team-shared), `index.md`
  (reusable-impl map), `conventions.md` + `stack-signals.md` (@imported by `.claude/CLAUDE.md`).
  Global tier: `~/.claude/claudehut/memory/` (opt-in).
- **Retrieval is JIT + relevance-ranked,** not a static dump. Each phase prompt pulls the
  **top-5** learnings most relevant to *this* task: `0.45·path + 0.30·tag + 0.10·title +
  0.15·usefulness_prior`. The prior rises for learnings that preceded a *pass* and falls for
  those that preceded a *fail/abandon* — so memory gets sharper with use.
- **Seed it (e.g. onboarding a repo):** drop entries into `learnings.jsonl` (one JSON object
  per line: `{title, category, tags, file, content, …}`). Retrieval picks them up immediately.
- **Memory MCP (optional):** if the `memory` MCP server is enabled, learnings mirror into its
  graph; the read path accepts the server's `memory.jsonl` or a configured `mcp-graph.json`.
- **Privacy:** every entry is secret-scanned (AWS/OpenAI/Anthropic keys, PEM, JWT, DB URLs)
  before append; matches are rejected, only the pattern type is logged.

---

## 7. Cost & budget control

- Each headless build/scaffold worker writes a `.cost` sidecar; a per-run
  `.claudehut/logs/run-summary.jsonl` records cost/tokens/`terminal_status`/`is_error`.
- The **worker-pool budget gate** sums cumulative real spend before each launch; on breach
  it **skips** remaining workers (exit 3, drops `budget-breach.json`) — it never kills a
  worker mid-write. Tune `budget.*` in the config (set `max_worker_pool_usd: 0` for unlimited).
- **Cheaper reviewers:** `agents.reviewer_models` lets style/mapping reviewers run on Haiku.

---

## 8. Rules — customizing conventions

`init` copies stack-matched rules into `.claude/rules/`, where Claude's **native loader**
auto-applies each when you open a file matching its `paths:` glob. To customize: edit the file
in `.claude/rules/`. `init --refresh` preserves your edits (SHA256-tracked in
`.claude/rules/.checksums.json`); `--force` overwrites. 47 rules across coding / architecture /
testing / security / performance / framework. The logical module map (core/spring/messaging/
quality) is documented in [`modularization/modules.json`](../modularization/modules.json).

---

## 9. Multiple tasks at once — worktrees

One session drives one branch/task. For parallel tasks use git worktrees:
```bash
git worktree add ../wt-feature-x feature/x
# open Claude Code in each worktree; each has its own .claudehut/ task state
```
Build-phase parallel groups already use worktrees internally (one builder per task, merged back).

---

## 10. Optional — the Agent-SDK orchestrator (experimental)

For headless/programmatic runs you can drive the pipeline with a deterministic JS loop instead
of the in-session prose orchestration:
```bash
cd sdk && npm install            # pulls @anthropic-ai/claude-agent-sdk
node orchestrator.mjs "Add a /health endpoint returning 200 OK"
# env: CLAUDEHUT_LOOP_MAX_RETRIES (3), CLAUDEHUT_MAX_POOL_USD (0=unlimited; exit 3 on breach)
```
It wraps the same state machine, dispatch-prompt enrichment, and bash build workers. Measured
parity vs the bash pipeline (trivial-sum-bug, k=3): pass@1 1.0/1.0, ~half cost, ~half wall, 0/3
budget breaches. Small sample — directional. The Claude Code plugin path remains primary. See
[`sdk/README.md`](../sdk/README.md).

---

## 11. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `/claudehut:*` skills don't appear | Plugin not loaded | `/reload-plugins` |
| `claudehut-state` not found | `bin/` not on PATH | Plugin auto-prepends; check `echo $PATH` |
| Hook output missing | `.claudehut/` not initialized | `/claudehut:init` |
| Stuck on `route`, `src/` edits blocked | No route recorded yet | Let the orchestrator run `/claudehut:route`, or run it; check `.claudehut/state/route-*.json` |
| `reuse-scan stale` during Build | Scan > `stale_threshold_minutes` old | Re-run `/claudehut:reuse-scan <topic>` |
| Stuck on `brainstorm` (full) | `design.md` not saved | Verify `.claudehut/specs/<task>-design.md` exists + non-empty |
| Build re-runs forever | Loop keeps finding `fail` | Hits `loop_max_retries` then escalates; inspect `findings/<task>-findings.json` |
| `BUDGET HALT` / exit 3 | Worker-pool cap reached | Raise `budget.max_worker_pool_usd` (or `0`); see `logs/budget-breach.json` |
| SDK orchestrator hangs / MCP errors headless | Plugin MCP servers block in headless | The eval harness neutralizes MCP; for direct SDK use, disable MCP servers you don't need |
| A trivial fix took the full pipeline | Classifier was conservative | Expected for anything ambiguous; phrase trivial intent explicitly, or override the route artifact |

---

## 12. Verifying the plugin itself

```bash
bash tests/run-all.sh                 # 479 deterministic assertions, no model calls
node --test sdk/test/                 # SDK control-flow unit tests (no $)
# opt-in, costs tokens (NOT in CI):
bash evals/run.sh trivial-sum-bug claudehut     # or: baseline | sdk
bash evals/compare.sh --variance evals/results/sdk.jsonl
```

CI runs the full deterministic suite on ubuntu + macOS (bash-3.2 compat) per push/PR.
