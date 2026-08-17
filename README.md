# ClaudeHut

> **v0.11.0** · a Claude Code plugin for **Java / Spring Boot backend engineers**.

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

`/claudehut:claudehut-init` **pre-indexes** the codebase once (stack, structure, memory, rules) — indexing is a
prerequisite, not a phase. After that, you describe a task and the workflow drives every phase
automatically, gating progress so you can't skip reuse, skip tests, or claim "done" without a clean review.

The full design lives in [`.claude/docs/design/`](.claude/docs/design/README.md).

---

## What's new in v0.9

- **Memory-engine hardening** — the cross-session learnings store takes a portable advisory lock (no lost
  updates when two Learn passes overlap), retires reinforced-but-dormant entries and resets stale recurrence
  flags (bounded growth), deterministically supersedes refined learnings (and **rebuilds**, not appends, the
  auto-promoted rule blocks so stale lines disappear), and **sanitizes ingested learning text** (neutralizes
  injection directives, strips URLs) with injected notes wrapped in an untrusted-data delimiter.
- **`claudehut-observability-reviewer`** — a Review-phase auditor gating metrics/tracing/SLO instrumentation on
  every new endpoint, listener, job, and outbound client (rule: `observability/instrumentation.md`).
- **`claudehut-contract-reviewer`** — a Review-phase auditor for Kafka/Avro/Protobuf schema compatibility,
  consumer-driven contract tests, and REST/gRPC backward-compat (rule: `framework/contract-compat.md`).
- **Deterministic completion gate** — `gate-done.sh` is the single authority. (v0.9.1 also ran an advisory
  `agent` hook on every `Stop`; v0.9.2 removed it — its two checks were already enforced by
  `claudehut-state set-review pass`, so it paid for a model call per turn to re-derive a settled decision.)
- **Eval self-checks** — a mermaid ultra-flow coverage guard in `conformance.sh`, per-task reference solutions
  (`evals/reference-check.sh`), and audit/investigation profile-rail gate tests.

---

## Install

```bash
# from the marketplace
/plugin marketplace add taipt1504/claudehut
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
/claudehut:claudehut-init          # one-time: detect stack → build index + memory + path-scoped rules
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
| **Brainstorm** | `brainstorm`        | `claudehut-brainstormer` (opus, `high` — fixed 6-step ideation pipeline: diverge ≥6 → cluster → score → premortem → recommend)                                                                                                                                            | ≥2 structurally distinct options + the per-task _enforcement set_                                        |
| **Spec**       | `write-spec`        | main thread                                                                                                                                                                                                                                                                | a templated spec (`tasks/<id>/spec.md`), **user-approved** before the gate arms                          |
| **Plan**       | `write-plan`        | `claudehut-planner` (opus)                                                                                                                                                                                                                                                 | a templated, test-first plan (`tasks/<id>/plan.md`), **user-approved**, mirrored to the native task list |
| **Implement**  | `implement`         | main thread **walks the plan phase by phase** (sequential spine); within each phase, disjoint `[P]` tasks → **parallel implementers** (one per task, concurrent, gated by `claudehut-worktree check-disjoint`); the native task list is updated at each **phase boundary** | code written **test-first** (RED → GREEN → REFACTOR), honoring the rules/playbooks                       |
| **Review**     | `review`            | **dynamically selected** auditors: `test-runner` + `reviewer` always; the specialists by actual impact, and on `trivial`/`small` the reviewer's fast-lane floor covers them                                                                                                                  | a verdict that audits exactly the enforcement set                                                        |
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
- **Iron-Law skills** order actions within a turn — reuse-first **+ the minimalism decision ladder**
  (Discover: _need-to-exist? → stdlib → Spring/dep → reuse → minimal new_), test-first (`implement`'s
  "no production code without a failing test"), evidence-first (Review). The safety floor (validation,
  error handling, security, transactions) is never cut for minimalism.
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

- **Agents** (`agents/`) — 14 specialists: `claudehut-explorer`, `claudehut-brainstormer`,
  `claudehut-reuse-scanner`, `claudehut-planner`, `claudehut-plan-reviewer`, `claudehut-implementer`,
  `claudehut-test-runner`, `claudehut-reviewer`, `claudehut-security-auditor`, `claudehut-perf-reviewer`,
  `claudehut-db-reviewer`, `claudehut-observability-reviewer`, `claudehut-contract-reviewer`,
  `claudehut-learner`. The implementer runs in an isolated worktree (forked from the **current branch HEAD**
  via `worktree.baseRef=head`, which `claudehut-init` sets — so a later phase's implementer sees the
  committed work of earlier phases); the reviewers are dispatched by `review`.
- **Skills** (`skills/`) — 9 total: orchestrator (`claudehut-workflow`, with the Phase-0 complexity triage) +
  indexer (`claudehut-init`) + one per phase (`discover`, `brainstorm`, `write-spec`, `write-plan`,
  `implement`, `review`, `capture-learnings`). The `implement` skill carries the TDD Iron Law and the
  tech-stack playbooks; `bin/claudehut-worktree` manages the parallel-implementer worktree lifecycle
  (check-disjoint / reconcile / sweep).
- **Rules** (`templates/rules/`, 55 files — incl. `observability/instrumentation` + `framework/contract-compat`) — generated per-project into `.claude/rules/` by `claudehut-init`,
  organized by domain (architecture / coding / framework / performance / security / testing) plus
  `project-structure.md` and `vocabulary.md`. Stack-gated at init — only the rules matching your detected
  stack (web / reactive / orm / messaging / cache / mapper) are emitted.
- **Hooks** (`hooks/hooks.json` + `scripts/`) — `SessionStart` bootstrap + phase/learnings injection,
  `UserPromptExpansion` slash skill-rail recorder, `PreToolUse`/`Stop` gates, `PostToolUse` Java formatting,
  `PostToolUseFailure` failure capture, `SubagentStop` verification, `PreCompact` state persistence.
- **CLI tools** (`bin/`) — `claudehut-init` (deterministic stack-detect + project-plane generator),
  `claudehut-state` (the sole writer of per-session phase state), `claudehut-worktree` (parallel-implementer worktree lifecycle: check-disjoint / reconcile / sweep), and `kafka-mcp` (an optional, documented
  **stub**).
- **MCP** — opt-in per project. ClaudeHut ships no active `.mcp.json`; `claudehut-init` reads
  `templates/mcp-recommendations.md` and _suggests_ `claude mcp add` servers in three buckets (tech-stack:
  postgres/mysql/redis/kafka/github · memory · research). The Review auditors degrade gracefully when none
  is connected (they review statically).
- **Summer KB** (`skills/summer-kb-setup/`) — service-scoped knowledge base for the Summer Framework
  (`io.f8a.summer`). The SessionStart hook auto-installs it into any consumer project (Summer deps
  detected, no `.claude/summer-kb/`), self-heals it when the plugin ships a newer bundle (`summerCommit`
  mismatch), and injects a mandatory grounding block into every session's context. Manual install/refresh:
  `/claudehut:summer-kb-setup`. Refresh pipeline (maintainer): regenerate the canonical KB in
  `java-common-ms/.claude/summer-kb/` → copy into `skills/summer-kb-setup/references/summer-kb/` + update its
  `.bundle-meta.json` `summerCommit` → bump the plugin version.

> **Note:** `bin/kafka-mcp` ships as a documented **stub** (a real implementation needs a language
> toolchain / Kafka client outside this package's build); it is offered as an optional recommendation. The
> workflow runs fully without any MCP server connected — MCP enriches, it does not gate.

### v0.11.0 — rules, skills & memory

v0.10.0 fixed what the workflow *enforces*. v0.11.0 fixes what it *carries*: the always-loaded index, the
rule corpus, and the learning loop — every finding measured against the 15 real installs before it was
acted on, and every fix pinned by an assertion that goes red when the fix is reverted.

- **Memory.** `MEMORY.md` is `@import`-ed whole, so every byte is re-read every turn. One install had grown
  to 98,809 B. `claudehut-init --migrate-memory` moves the learner's per-task blocks into a sibling
  `MEMORY-history.md` that is never imported — 63,507 B off every turn, and it MOVES rather than truncates,
  so a hand-written section survives because it does not match, not because it was detected. The budget is
  now stated in **bytes**: three of the four over-budget files passed the old line cap.
- **The learning loop actually closes.** Three independent breaks meant `.applied` was permanently 0 and the
  failure harvest produced nothing. `PostToolUseFailure` sends no `tool_error` object at all — the field
  paths were reading something that does not exist, which is why 682 of 682 staged records were hollow.
- **Rules.** Java-version and ORM gating (a JPA rule was installing into every R2DBC service), dead globs
  revived, `@MockitoBean`/`MockMvcTester` for Boot 3.4, and three new rules including money arithmetic —
  a payments corpus with no rule about `BigDecimal`.
- **Federated learnings** (opt-in): a service with an empty store draws its siblings' proven lessons,
  tagged with their origin and ranked below its own.
- **A forked session** ran no bootstrap at all, which silently made the whole workflow optional.
- **`claudehut-init --audit`** reports rule drift read-only, and CI now checks MCP tool names, skill
  descriptions, and every documentation anchor.

### v0.10.0 — enforcement plane

v0.9.2 cut what the workflow *costs*. v0.10.0 fixes what it *enforces*, after an audit found that several
gates were not running at all.

- **SubagentStop verification had never executed.** It matched bare agent names, but the runtime delivers the
  plugin-scoped identifier (`claudehut:claudehut-planner`) for plugin-shipped subagents, so all four artifact
  contracts fell through to a no-op. The evals passed because every fixture fed the bare name — they certified
  a code path that never ran. Fixed, and the production payload shape is now pinned.
- **The write gate could be bypassed, and could also wedge.** Exemptions matched the absolute path, so a
  directory *above* the checkout decided the outcome: a repo under `~/Projects/tests/` had the gate disabled
  wholesale, one under any `.../src/main/...` had every write denied. Exemptions are now matched
  project-relative, test roots are named explicitly rather than substring-matched, and `state/` is excluded
  from the store exemption — it holds the file the gate reads for `bypass`, so one write could disable it.
- **`bin/claudehut-state` lost concurrent updates** (measured 15/15 on two orthogonal fields). It now takes
  the same advisory lock the learnings store uses, plus a guard that store was missing.
- **Rules that never reached a project.** `testing/testcontainers.md` was tagged for a `test=` axis that did
  not exist, and `performance/caching.md` listed two cache values in a tag matched as one literal token.
  Both shipped in the repo and emitted nowhere. Tags now accept alternatives, and a `test=` axis exists.
- **Three contradictory architecture rules** (DDD, hexagonal, CQRS) shipped together into every project.
  There is no reliable detector, so the default now emits none and a project declares its style with
  `CLAUDEHUT_ARCH=ddd|hexagonal|cqrs`. Upgrading never deletes anything: `--refresh-rules` (which
  `bootstrap.sh` runs automatically on a version bump) only *reports* rules whose stack tag went inactive.
  Removing them is opt-in with `claudehut-init --refresh-rules --retire-inactive`, and even then a file the
  learner promoted pitfalls into is kept.
- **Stack detection reads submodule build files.** It read only the root `pom.xml`/`build.gradle`, so a
  multi-module Spring project — the plugin's core audience — detected no dependencies and every stack-gated
  rule was treated as inactive. Tags also accept alternatives now (`cache=redis,caffeine`), with bare values
  inheriting the axis.
- **Plan orchestration left the per-implementer preload.** `skills/implement/SKILL.md` is injected whole into
  every implementer, which has no Agent or task tools; the phase-walk machinery moved to
  `references/orchestration.md`, read by the main thread.
- **MCP recommendations point at servers that exist.** `mcp__postgres__query` was in three agents' tool
  lists; the recommended server has no tool by that name (it is `execute_sql`), and the package itself is
  deprecated on npm — so a "configured" db reviewer silently degraded to a static review. postgres now
  targets `postgres-mcp` with `--access-mode=restricted`, whose default is *unrestricted*, i.e. full write.
  The unimplemented `bin/kafka-mcp` stub is replaced by Confluent's `@confluentinc/mcp-confluent`, pinned
  with its own `--allow-tools` flag to five read-only tools (`claude mcp add` has no tool filter).
- **Two observation hooks** (`SubagentStart`, `InstructionsLoaded`) record what the runtime actually
  dispatches and loads, into session sidecars. Nothing acts on them yet — that is the point. Moving the
  auditor payload into a hook is only safe once there is evidence the hook fires.

The eval suite went from 406 passing with 2 failures to **457 passing with none**. Every fix in this release
has a test that fails when the fix is reverted; that check surfaced two assertions which had been passing for
the wrong reason.

**Java code intelligence (jdtls).** The plugin ships `.lsp.json` wiring `.java` to
[jdtls](https://github.com/eclipse-jdtls/eclipse.jdt.ls) with `diagnostics: false` — navigation without
pushing diagnostics into context after every edit.

**You must install the binary yourself**; a plugin configures the connection, it does not bundle the server.
If `jdtls` is not on `PATH` you will see `Executable not found in $PATH` in the `/plugin` Errors tab, and
nothing else changes — Claude Code skips a server it cannot start and the rest of the plugin is unaffected.
`restartOnCrash`/`shutdownTimeout` are deliberately unset: they need Claude Code v2.1.205+, and on older
versions setting either makes Claude Code skip the server entirely, with the reason visible only under
`claude --debug`.

This config has not been exercised against a live Spring service by the maintainers — the eval suite cannot
verify that a language server actually starts. Verify with `claude --debug` on a real project before relying
on it, and report back if jdtls needs `args` on your setup.

### Token cost (v0.9.2)

The workflow's cost is dominated by what is paid *repeatedly* — per session, per prompt, per subagent
dispatch — not by any single prompt. v0.9.2 attacks those paths:

- **Model routing.** Checklist and mechanical agents run on cheaper models: `test-runner` and `explorer` on
  Haiku, the five review auditors + `plan-reviewer` on Sonnet. Opus is reserved for open-ended judgment
  (`brainstormer`, `planner`, `implementer`) and the security floor (`security-auditor`). `effort: xhigh`
  survives only on `planner` and `security-auditor` — thinking tokens bill at output rates.
- **Session start** injects `skills/claudehut-workflow/references/digest.md` (~2 KB: tiers, profiles, laws,
  phase map) instead of the full 10 KB orchestrator, which is re-paid on every resume/clear/compact. Load the
  full skill on demand with `/claudehut:claudehut-workflow`.
- **Per-prompt injection is delta-only.** The full re-anchor + Phase-0 triage block fires on a phase *change*;
  repeat prompts in the same phase get a one-line anchor. Learnings already injected at session start are
  excluded rather than re-sent, and each entry is length-capped.
- **Review fan-out is tier-aware.** trivial/small skip the perf, db, and contract specialists — the general
  reviewer's fast-lane fallback table carries the same N+1 / EAGER / `.block()` / `@Entity` floor. Fix→re-spawn
  is capped at 2 rounds (plan REVISE likewise), and dispatch prompts carry the diff hunks so auditors don't
  each re-read the same files.
- **No per-Stop model call.** The advisory Haiku completion-verifier hook is gone; its two checks were already
  enforced deterministically by `claudehut-state set-review pass`.

**Recommended project setting.** Since Claude Code v2.1.198 the built-in `Explore` agent inherits the session
model (capped at Opus) instead of always running on Haiku, so exploration silently costs whatever the session
costs. A user or project subagent named `Explore` overrides the built-in and keeps its own `model` field — add
`.claude/agents/Explore.md` with `model: haiku` to keep exploration on a lower-cost model.
See [Claude Code › subagents](https://code.claude.com/docs/en/sub-agents).

---

## Evals

All tests are reproducible from the repo. The deterministic suite needs no Claude; the probes/runner drive
Claude Code headlessly and cost tokens.

```bash
# deterministic (free, no Claude needed) — 608 assertions, all green on the release commit
evals/conformance.sh              # 270  structural + behavioural wiring checks
evals/gate-tests.sh               # 105  write/done enforcement gates
evals/init-tests.sh               # 102  claudehut-init: detection, plane generation, migrations
evals/merge-learnings-tests.sh    #  51  learnings merge, prune, injection, federation
evals/reference-check.sh          #  16  reference oracles, MCP inventory, doc anchors, NUL bytes,
                                  #       and the freshness of the counts in this very list
evals/trigger-eval.sh --validate  #  19  skill-description trigger fixtures
evals/worktree-tests.sh           #  23  parallel-implementer worktree lifecycle
evals/artifact-oracle-tests.sh    #  14  artifact shape oracles
evals/ranker-tests.sh             #   8  reuse ranker
scripts/lint-prompt-length.sh     #       prompt budgets + provenance (--self-test to check the linter)

# live (drives Claude headlessly; costs tokens) — NOT in CI
evals/run.sh [--live]             # scenario runner over fixtures (answer-key-leak guarded; dry-runs without --live)
evals/trigger-eval.sh --skill X   # does a skill's DESCRIPTION actually trigger it? 16 queries x 3 runs
evals/bootstrap-acceptance.sh     # one real session, one ordinary request: did SessionStart fire at all?
evals/playbook-read-probe.sh      # create-time playbook-read behaviour
evals/p7-init.sh                  # init invocation produces the project plane
```

**Release checklist** — the deterministic suite runs in CI; these do not, and a release should not ship
without them:

```bash
bash evals/bootstrap-acceptance.sh          # the highest-consequence single point of failure: if the
                                            # SessionStart hook stops firing, the write gate, the skill
                                            # rail and the profile gate are all silently inert, and every
                                            # other eval still passes because they call the scripts directly
bash evals/trigger-eval.sh --skill <skill>  # required after ANY change to a skill's description:
                                            # --validate goes red until the fixture is refreshed, and
                                            # refreshing it without re-running this is a false green
claude plugin validate . --strict
```

Measured findings and the prioritized optimization log are in [`evals/EVAL-REPORT.md`](evals/EVAL-REPORT.md).

---

## License

MIT — see [LICENSE](LICENSE).
