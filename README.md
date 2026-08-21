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
# recommended — the shell form installs to USER scope by default
claude plugin marketplace add taipt1504/claudehut
claude plugin install claudehut@claudehut-marketplace

# or load locally for a session, without installing
claude --plugin-dir /path/to/claudehut
```

**Then reload.** `claude plugin install` does not run inside a session, so Claude Code picks the plugin
up at the next start or when you run `/reload-plugins`.

**Install at user scope, not project scope.** ClaudeHut is a personal workflow tool: it changes how *you*
work through a task, not how the repository builds. The shell form above defaults to user scope
(`--scope user` is the explicit spelling). The interactive form — `/plugin marketplace add …` then
`/plugin install …` — opens a picker where scope is a free choice, and choosing **project** writes the
plugin into a **committed** `.claude/settings.json`, enabling it for every collaborator on the repo.
Beyond the consent question, project scope is also the more restricted mode: project plugins load only
after the folder-trust gate, and components that run code are restricted further. Personal-scope plugins
have none of those restrictions. If you do want it repo-wide, that is the second snippet:

```bash
claude plugin install claudehut@claudehut-marketplace --scope project
```

**Updates are manual.** Auto-update is enabled by default only for official Anthropic marketplaces;
third-party and local marketplaces — which is what `claudehut-marketplace` is — have it **off** by
default. Nothing updates in the background until you turn it on (`/plugin` → Marketplaces → Enable
auto-update). Explicit pulls always work:

```bash
claude plugin update claudehut@claudehut-marketplace   # or /plugin update
```

If you installed before this section existed, your marketplace may be registered under a different
name — check with `claude plugin marketplace list` and use the name it prints, not the one above.

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

A second pass then audited the surfaces the first one did not touch — the 14 agents, the parallel-worktree
tool, the manifest, and the eval harness itself. The recurring finding is the same one v0.11 started with:
**a mechanism that is configured, green, and does nothing.**

- **The parallel-implementer tool could destroy committed work.** A detached-HEAD worktree was classified
  "merged" — the branch-name comparison resolved to the *main* repo's HEAD, so the question became "is
  main's HEAD an ancestor of main's HEAD" — and `sweep` deleted it while printing "kept = dirty or
  unmerged". The commit became unreachable and GC-eligible. Nine more defects in the same file, all
  reproduced end to end: repo-root files like `pom.xml` were invisible to the collision check (so two
  parallel tasks editing it were scheduled concurrently), a refused plan still printed the refused phase
  as a parallel batch, `[P]`'s dependency half was never checked at all, a project path containing a space
  hid every worktree from `status` and `sweep`, and a verified merge with an empty test command merged
  without running a test while reporting success. The suite covering that file went from 23 assertions
  to 53.
- **The authoritative load check had never once produced a verdict.** `scripts/load-probe.sh` — named
  "the authoritative load check" twice in CI config — passed `--output-format stream-json` without
  `--verbose`, which the CLI rejects outright, so it failed on a healthy plugin every time it was ever
  run. Its gate was vacuous besides: it read `plugin_errors` from an event that has no such key, so a `//`
  default turned "field missing" into "everything is fine". It now diffs the runtime's actual component
  roster against the tree, and it is the first item on the release checklist.
- **Every review loop is bounded.** Six auditors and the explorer had a self-loop with no counter — the
  worst of them on the most expensive agent in the corpus. Each now caps at two rounds and emits its
  coverage table with unresolved rows marked unverified, which *blocks* at the review gate rather than
  passing. A turn cap would have done the opposite; that is why it is still refused.
- **The plugin stopped contradicting itself.** The rigor contract told five of six auditors they run on a
  model they do not run on, in the sentence that sets reasoning depth. The discover skill said three
  different things about whether a `small` task dispatches subagents. Three shipped rule files named an
  agent that has never existed and put review in the wrong phase. All corrected, each with an assertion.
- **Capability trimmed to what the bodies actually use.** The security auditor could read live Kafka
  message payloads with no procedure that called it. Two other auditors were asked to do things their
  tool lists made impossible. And "read-only, do not edit" named file edits but not git state, while up
  to six auditors share one checkout — one `git stash` to "compare against main" corrupts what the other
  five are reading.
- **The dispatch ledger survives.** It had been written into a directory `claudehut-init` gitignores, so
  across every repo on this machine exactly two ledger files existed — which is why no dispatch-frequency
  claim in the audit is empirical. It now persists, and pairs each start with its stop. Every field was
  measured from a real payload first; `effort` is deliberately not recorded at dispatch time because the
  start event does not carry it.
- **Install and update guidance now matches how the tool is meant to be used** — user scope by the shell
  form, with the project-scope consequences and the manual-update default both stated.

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

**No `args` are needed — that standing question is answered.** The upstream `jdtls` Python launcher
already registers `-data` with a default and synthesizes the `-configuration` equivalent itself
(`jdtls.py` sets `-Dosgi.sharedConfiguration.area` plus `.readOnly` and `cascaded`). The
`-configuration`/`-data` pair that eclipse.jdt.ls's own README calls user-provided applies to the raw
`java -jar …launcher.jar` invocation, not to the wrapper. **Do not add `args` speculatively** — that
converts a working default into a definitely-broken literal path.

One conditional caveat: the default workspace directory is keyed on the sha1 of `basename(getcwd())`, so
two checkouts whose directory basenames match — `~/work/ewallet` and `~/archive/ewallet` — would share
one workspace index, against the server's own "unique per workspace/project" requirement. Nothing
documents which cwd Claude Code spawns an LSP server with, so treat this as conditional. If you want
per-project isolation explicitly:

```json
"args": ["-data", "${CLAUDE_PROJECT_DIR}/.claude/claudehut/jdtls-data"]
```

Use `${CLAUDE_PROJECT_DIR}` and not `${workspaceFolder}` — plugin configs expand exactly three
placeholders (`${CLAUDE_PLUGIN_ROOT}`, `${CLAUDE_PLUGIN_DATA}`, `${CLAUDE_PROJECT_DIR}`);
`workspaceFolder` is a sibling config *field*, not a placeholder, and would ship as an unexpanded
literal.

**jdtls requires Java 21, which is above this plugin's own stated target.** The language server — not
the wrapper — requires a Java 21 runtime at minimum, and `jdtls.py` resolves the JVM from `$JAVA_HOME`
first, raising before the LSP handshake if the major version is below 21. So on a machine whose
`JAVA_HOME` points at a project JDK 17, `jdtls` throws and Claude Code silently skips the server — the
same degradation as a missing binary, **with the binary present on `PATH`**. `--no-validate-java-version`
is not a fix: it suppresses a check whose requirement the server still enforces. Point jdtls at a
JDK 21+ without moving your project's JVM:

```json
"args": ["--java-executable", "/path/to/jdk21/bin/java"]
```

or equivalently `"env": {"JAVA_HOME": "/path/to/jdk21"}`. Both are documented `lspServers` fields.

This config has not been exercised against a live Spring service by the maintainers, and the eval suite
cannot close that gap: `.lsp.json` sets `diagnostics: false`, so an empty `mcp__ide__getDiagnostics` is
the *expected* result and can never distinguish a working server from a dead one — a diagnostics-based
probe produces a false green. The check that works is **navigation**: go-to-definition on an injected
bean, or hover on an `@Service`, in a real single-module Spring service. A resolved cross-file symbol
proves the server started and has a usable index.

### Token cost (v0.9.2)

The workflow's cost is dominated by what is paid *repeatedly* — per session, per prompt, per subagent
dispatch — not by any single prompt. v0.9.2 attacks those paths:

- **Model routing.** Checklist and mechanical agents run on cheaper models: `test-runner` and `explorer` on
  Haiku; the five conditional specialists (`perf`, `db`, `contract`, `observability`, `plan-reviewer`) on
  Sonnet — each has one defect class and a fallback table. Opus is reserved for open-ended judgment
  (`brainstormer`, `planner`, `implementer`), the security floor (`security-auditor`), and the general
  `reviewer`, which is the only always-on auditor and the one asked for open-ended judgment on every diff.
  `effort: xhigh` survives only on `planner` and `security-auditor` — thinking tokens bill at output rates.
  Elsewhere `effort` is declared only where it differs from the model's default, so setting your session to
  a lower effort is not silently overridden.
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

**One environment variable outranks every tier above.** Claude Code resolves a subagent's model in this
order: `CLAUDE_CODE_SUBAGENT_MODEL` → a per-invocation `model` → the agent's frontmatter `model` → the
main conversation's model. So a single `export CLAUDE_CODE_SUBAGENT_MODEL=opus` collapses all fourteen
tiers onto one model, silently, with no signal in the transcript — every table in this section stops
being true. If your dispatches cost more than this section predicts, check that variable first. Three
narrowings worth knowing: `inherit` as a value is a no-op equal to unset; a model blocked by
`availableModels` falls back rather than overriding; and `availableModels` is the user-side lever that
*can* cap this plugin's Opus agents to Sonnet if you want a ceiling.

**Measuring it: `/usage`.** Run it in any session and press `d` / `w` to toggle 24h vs 7d. It reports
recent usage attributed to skills, subagents, plugins and individual MCP servers, each as a percentage
of the total, plus behaviour flags for long context and cache misses when either accounts for 10% or
more. It is computed from local session history — no collector, no telemetry setup, and it is unaffected
by running a stale cached copy of this plugin. It is the only source of real dispatch-cost data that
needs zero setup. Two caveats: whether the attribution panel renders this plugin's agent and skill names
verbatim or redacts them is unverified, and do not read the cache-miss flag as evidence of fan-out —
that flag is defined by a *time gap*, the first message after a break longer than the cache lifetime.

If you do wire up OpenTelemetry, group `claude_code.token.usage` on `query_source × model × effort`; all
three emit verbatim. Per-agent attribution is not available to a plugin like this one: only built-in
agent names and agents from official marketplaces appear verbatim in the counters, so all fourteen
ClaudeHut agents collapse to `"custom"` and the plugin name to `"third-party"`. Prefer token counts over
dollars on a seat plan — usage inside the seat allowance is not metered in dollars. `bin/claudehut-init`
writes `OTEL_RESOURCE_ATTRIBUTES=service.name=<repo>` into the project's `.claude/settings.json` so
tokens slice per repository; the exporter endpoint and `OTEL_EXPORTER_OTLP_HEADERS` stay in your own
environment and are deliberately never written to that committed file.

---

## Evals

All tests are reproducible from the repo. The deterministic suite needs no Claude; the probes/runner drive
Claude Code headlessly and cost tokens.

```bash
# deterministic (free, no Claude needed) — 748 assertions, all green on the release commit
evals/conformance.sh              # 287  structural + behavioural wiring checks
evals/gate-tests.sh               # 171  write/done enforcement gates
evals/init-tests.sh               # 115  claudehut-init: detection, plane generation, migrations
evals/merge-learnings-tests.sh    #  51  learnings merge, prune, injection, federation
evals/reference-check.sh          #  24  reference oracles, MCP inventory, doc anchors, NUL bytes,
                                  #       and the freshness of the counts in this very list
evals/trigger-eval.sh --validate  #  25  skill-description trigger fixtures
evals/worktree-tests.sh           #  53  parallel-implementer worktree lifecycle
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
bash scripts/load-probe.sh                  # FIRST. The authoritative load check: it starts a real
                                            # headless session and diffs the runtime's component roster
                                            # against the tree. `claude plugin validate` did NOT catch
                                            # the over-declare bug that broke runtime load, because it
                                            # only reads marketplace.json. Declaring `agents`,
                                            # `commands`, `outputStyles` or `workflows` in plugin.json
                                            # REPLACES the default scan, so a well-meant "scoping"
                                            # edit silently unregisters everything it does not list
bash evals/bootstrap-acceptance.sh          # the highest-consequence single point of failure: if the
                                            # SessionStart hook stops firing, the write gate, the skill
                                            # rail and the profile gate are all silently inert, and every
                                            # other eval still passes because they call the scripts directly
bash evals/trigger-eval.sh --skill <skill>  # required after ANY change to a skill's description:
                                            # --validate goes red until the fixture is refreshed, and
                                            # refreshing it without re-running this is a false green
claude plugin validate . --strict           # narrower than it looks: it validates marketplace.json
                                            # ONLY, and CI runs it only "if CLI present", so it can
                                            # skip with no signal. Not a substitute for load-probe.sh
```

Measured findings and the prioritized optimization log are in [`evals/EVAL-REPORT.md`](evals/EVAL-REPORT.md).

---

## License

MIT — see [LICENSE](LICENSE).
