# ClaudeHut

> **v0.4.0** · a Claude Code plugin for **Java / Spring Boot backend engineers**.

ClaudeHut turns a single task description into a disciplined, seven-phase engineering loop — and **enforces**
it with native Claude Code mechanisms (hooks, skills, subagents, path-scoped rules) rather than relying on
the model to remember:

```
            ┌────────────────────────────────────────────────────────────────────┐
  init  →   │  Discover → Brainstorm → Spec → Plan → Implement → Review → Learn    │
(pre-index) └────────────────────────────────────────────────────────────────────┘
             reuse-first  ideation              test-first   evidence-first  reinforced
```

A **complexity triage** (Phase 0) routes each task: `trivial`/`small` tasks skip the deliberation phases
(Brainstorm/Spec/Plan) through a **gate-verified fast lane** (≤2 files, no security/auth/migration paths —
checked deterministically, not by model judgment); the safety rails (reuse-scan, test-first, Review) are
never skipped in any tier.

`/claudehut:init` **pre-indexes** the codebase once (stack, structure, memory, rules) — indexing is a
prerequisite, not a phase. After that, you describe a task and the workflow drives every phase
automatically, gating progress so you can't skip reuse, skip tests, or claim "done" without a clean review.

The full design lives in [`.claude/docs/design/`](.claude/docs/design/README.md).

---

## Install

```bash
# from the marketplace
/plugin marketplace add claudehut/claudehut
/plugin install claudehut@claudehut-marketplace

# or load locally for a session
claude --plugin-dir /path/to/claudehut
```

ClaudeHut ships **no** MCP servers and prompts for **no** credentials. MCP is opt-in per project (see
[Components → MCP](#components)).

### Requirements

- **Claude Code** (CLI / desktop / IDE).
- **`jq`** on `PATH` — the state CLI and gate hooks require it.
- A **Java / Spring Boot** project under **git** (Gradle or Maven). Indexing detects the stack from your
  build files; the workflow's standards target Spring Boot 3.x / Java 17+.

---

## Quick start

```text
/claudehut:init          # one-time: detect stack → build index + memory + path-scoped rules
<describe your task>     # ClaudeHut triages complexity, then drives Discover → … → Learn automatically
```

The orchestrator skill (`claudehut:claudehut-workflow`) is injected at session start and routes each phase
to its skills and agents. You don't invoke the phases by hand — the workflow does. Everything it generates
lives under `.claude/claudehut/` (index, memory, one `tasks/NNNN-<slug>/` dir per task holding its
reuse-scan/spec/plan/review, per-session state, learnings) and
`.claude/rules/` (the generated tech-stack standards).

---

## The seven phases

| Phase          | Skill               | Drives                                                                                                                                                                                                                                                                     | Output                                                                                                   |
| -------------- | ------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| **Discover**   | `discover`          | `claudehut-explorer` ∥ `claudehut-reuse-scanner` (one message, concurrent)                                                                                                                                                                                                 | codebase grounding + the **reuse-scan** artifact (required in every tier)                                |
| **Brainstorm** | `brainstorm`        | `claudehut-brainstormer` (opus, `xhigh` — fixed 6-step ideation pipeline: diverge ≥6 → cluster → score → premortem → recommend)                                                                                                                                            | ≥2 structurally distinct options + the per-task _enforcement set_                                        |
| **Spec**       | `write-spec`        | main thread                                                                                                                                                                                                                                                                | a templated spec (`tasks/<id>/spec.md`), **user-approved** before the gate arms                          |
| **Plan**       | `write-plan`        | `claudehut-planner` (opus)                                                                                                                                                                                                                                                 | a templated, test-first plan (`tasks/<id>/plan.md`), **user-approved**, mirrored to the native task list |
| **Implement**  | `implement`         | main thread **walks the plan phase by phase** (sequential spine); within each phase, disjoint `[P]` tasks → **parallel implementers** (one per task, concurrent, gated by `claudehut-worktree check-disjoint`); the native task list is updated at each **phase boundary** | code written **test-first** (RED → GREEN → REFACTOR), honoring the rules/playbooks                       |
| **Review**     | `review`            | **dynamically selected** auditors: `test-runner` + `reviewer` always; `security-auditor` (over-included), `perf-reviewer`, `db-reviewer` by actual impact                                                                                                                  | a verdict that audits exactly the enforcement set                                                        |
| **Learn**      | `capture-learnings` | `claudehut-learner`                                                                                                                                                                                                                                                        | append-only `learnings.jsonl` re-injected into future sessions                                           |

---

## How enforcement works

- **Write gate** (`PreToolUse`, tier-aware): no new production code until a reuse-scan artifact exists
  (**every tier**) plus a spec **and** plan (**full tier**). Fast lanes (`trivial`/`small`) skip spec/plan but
  only within a **deterministically checked bound** (≤2 changed files, no security/auth/migration paths) —
  exceed it and the gate denies and forces escalation to full. Test paths (`*Test.java`, `*IT.java`,
  `*/test/*`) are always allowed so the RED test can come first. The gate also verifies the named artifacts
  actually exist at canonical paths — a flag alone won't unlock it.
- **Completion gate** (`Stop`, tier-aware): you can't claim "done" until Review reports zero outstanding
  items and — in full/small tiers — the Learn pass has run (trivial legitimately ends at review-pass; honors
  the native consecutive-Stop cap). Sessions that never engaged the workflow aren't blocked.
- **Iron-Law skills** order actions within a turn — reuse-first (Discover), test-first (`implement`'s
  "no production code without a failing test"), evidence-first (Review).
- **Path-scoped rules** auto-load the right standard when you **open/edit** a matching file; **reference
  playbooks** carry the deeper create-time standard (see below).

### Rules (edit-time) + playbooks (create-time)

The tech-stack standards live on two surfaces, split by **measured** Claude Code behavior:

- **`.claude/rules/*`** — path-scoped, terse. They auto-load reliably when you **read or edit an existing**
  matching file.
- **`skills/implement/references/*.md`** — 9 context7-researched playbooks (web, jpa, reactive, messaging,
  caching, security, persistence-ops, testing, java-lang), preloaded with the `implement` skill. They carry
  the deep best-practice standard the path-rule would otherwise supply at **create** time (creating a new
  file doesn't trigger a path-rule). The highest-cost must-dos (e.g. security **deny-by-default**) are also
  inlined directly into the always-loaded skill body as a safety floor.

### Bypass / overrides

```bash
# the state CLI is the SOLE writer of session state (hooks only read it):
"${CLAUDE_PLUGIN_ROOT}/bin/claudehut-state" --session "$CLAUDE_SESSION_ID" set-bypass true   # disable gates this session
"${CLAUDE_PLUGIN_ROOT}/bin/claudehut-state" --session "$CLAUDE_SESSION_ID" set-complexity trivial  # fast-lane a trivial task (gate still verifies the bound)
```

The gates also fail **open** (allow) on a missing/stale state file, and you can disable all hooks via Claude
Code's `disableAllHooks` setting.

---

## Components

- **Agents** (`agents/`) — 11 specialists: `claudehut-explorer`, `claudehut-brainstormer`,
  `claudehut-reuse-scanner`, `claudehut-planner`, `claudehut-implementer`, `claudehut-test-runner`,
  `claudehut-reviewer`, `claudehut-security-auditor`, `claudehut-perf-reviewer`, `claudehut-db-reviewer`,
  `claudehut-learner`. The implementer runs in an isolated worktree (forked from the **current branch HEAD**
  via `worktree.baseRef=head`, which `claudehut-init` sets — so a later phase's implementer sees the
  committed work of earlier phases); the reviewers are dispatched by `review`.
- **Skills** (`skills/`) — 9 total: orchestrator (`claudehut-workflow`, with the Phase-0 complexity triage) +
  indexer (`claudehut-init`) + one per phase (`discover`, `brainstorm`, `write-spec`, `write-plan`,
  `implement`, `review`, `capture-learnings`). The `implement` skill carries the TDD Iron Law and the
  tech-stack playbooks; `bin/claudehut-worktree` manages the parallel-implementer worktree lifecycle
  (check-disjoint / reconcile / sweep).
- **Rules** (`templates/rules/`, 50 files) — generated per-project into `.claude/rules/` by `claudehut-init`,
  organized by domain (architecture / coding / framework / performance / security / testing) plus
  `project-structure.md` and `vocabulary.md`. Stack-gated at init — only the rules matching your detected
  stack (web / reactive / orm / messaging / cache / mapper) are emitted.
- **Hooks** (`hooks/hooks.json` + `scripts/`) — `SessionStart` bootstrap + phase/learnings injection,
  `PreToolUse`/`Stop` gates, `PostToolUse` Java formatting, `SubagentStop` verification, `PreCompact` state
  persistence.
- **CLI tools** (`bin/`) — `claudehut-init` (deterministic stack-detect + project-plane generator),
  `claudehut-state` (the sole writer of per-session phase state), `claudehut-worktree` (parallel-implementer worktree lifecycle: check-disjoint / reconcile / sweep), and `kafka-mcp` (an optional, documented
  **stub**).
- **MCP** — opt-in per project. ClaudeHut ships no active `.mcp.json`; `claudehut-init` reads
  `templates/mcp-recommendations.md` and _suggests_ `claude mcp add` servers in three buckets (tech-stack:
  postgres/mysql/redis/kafka/github · memory · research). The Review auditors degrade gracefully when none
  is connected (they review statically).

> **Note:** `bin/kafka-mcp` ships as a documented **stub** (a real implementation needs a language
> toolchain / Kafka client outside this package's build); it is offered as an optional recommendation. The
> workflow runs fully without any MCP server connected — MCP enriches, it does not gate.

---

## Evals

All tests are reproducible from the repo. The deterministic suite needs no Claude; the probes/runner drive
Claude Code headlessly and cost tokens.

```bash
# deterministic (free, no Claude needed)
evals/conformance.sh          # 49 structural/wiring checks
evals/gate-tests.sh           # 21 tests of the write/done enforcement gates
evals/init-tests.sh           # 36 tests of claudehut-init (detect + plane generation)
evals/ranker-tests.sh         # 5 reuse-ranker tests

# live (drives Claude headlessly; costs tokens)
evals/run.sh [--live]         # scenario runner over fixtures (answer-key-leak guarded, dry-runs without --live)
evals/playbook-read-probe.sh  # measures create-time playbook-read behavior
evals/p7-init.sh              # confirms init invocation produces the project plane
```

Measured findings and the prioritized optimization log are in [`evals/EVAL-REPORT.md`](evals/EVAL-REPORT.md).

---

## License

MIT — see [LICENSE](LICENSE).
