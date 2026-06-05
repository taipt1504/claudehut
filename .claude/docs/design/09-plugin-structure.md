# ClaudeHut Design — 09. Plugin Structure

> Part of the **ClaudeHut** design document set. See [README](./README.md). Physical layout summarised in [02 §5](./02-architecture.md#5-where-each-thing-physically-lives).
> **Status:** Design v1 · **Pillar focus:** P6 (native integration). **Native mechanism:** `plugin.json` manifest + `marketplace.json` + plugin component directories.

ClaudeHut ships as a single plugin directory. The plugin is a **static plane** — its files are replaced on every update and must never hold runtime state. All persistent state lives in the **project plane** generated under `${CLAUDE_PROJECT_DIR}/.claude/`. This document fixes the canonical directory tree, specifies every field in `plugin.json` and `marketplace.json`, maps each file to its specification document, and records the native constraints the layout must honor.

## Table of Contents

- [1. Directory tree (the whole plugin)](#1-directory-tree-the-whole-plugin)
- [2. plugin.json (annotated)](#2-pluginjson-annotated)
- [3. marketplace.json](#3-marketplacejson)
- [4. File-by-file map](#4-file-by-file-map)
- [5. Naming & namespacing conventions](#5-naming--namespacing-conventions)
- [6. Native constraints honored](#6-native-constraints-honored)

---

## 1. Directory tree (the whole plugin)

Two planes, visually separated. The plugin plane is read-only at runtime; the project plane is generated once by `claudehut-init` and mutated throughout the project's life.

### Plugin plane — `${CLAUDE_PLUGIN_ROOT}/` (static, replaced on update)

```
claudehut/                                  # static plugin plane
├── .claude-plugin/
│   ├── plugin.json                         # plugin manifest (§2)
│   └── marketplace.json                    # marketplace listing (§3)
│
├── agents/                                 # 11 subagent definitions [03]
│   ├── claudehut-explorer.md
│   ├── claudehut-brainstormer.md
│   ├── claudehut-reuse-scanner.md
│   ├── claudehut-planner.md
│   ├── claudehut-implementer.md
│   ├── claudehut-test-runner.md
│   ├── claudehut-reviewer.md
│   ├── claudehut-security-auditor.md
│   ├── claudehut-perf-reviewer.md
│   ├── claudehut-db-reviewer.md
│   └── claudehut-learner.md
│
├── skills/                                 # 9 skills [04]
│   ├── claudehut-workflow/
│   │   └── SKILL.md                        # orchestrator (injected at SessionStart); 7-phase map + tier triage
│   ├── claudehut-init/
│   │   └── SKILL.md                        # bootstrap skill → /claudehut:init
│   ├── discover/
│   │   └── SKILL.md                        # Discover phase (NEW v0.4): explorer ∥ reuse-scanner; Reuse Iron Law; every tier
│   ├── brainstorm/
│   │   └── SKILL.md                        # generic ideation; consumes Discover output; dispatches brainstormer; enforcement set
│   ├── write-spec/
│   │   ├── SKILL.md
│   │   └── references/
│   │       └── spec-template.md            # spec-kit/EARS/MADR/Google synthesis; right-sized by task type
│   ├── write-plan/
│   │   ├── SKILL.md
│   │   └── references/
│   │       └── plan-template.md            # spec-kit plan template; T-xxx table + decision summary §1
│   ├── implement/
│   │   ├── SKILL.md                        # Iron Law: test-first enforcement
│   │   └── references/                     # 9 context7-researched best-practice playbooks; preloaded by the implement skill at CREATE-time
│   │       ├── web.md
│   │       ├── jpa.md
│   │       ├── reactive.md
│   │       ├── messaging.md
│   │       ├── caching.md
│   │       ├── security.md
│   │       ├── persistence-ops.md
│   │       ├── testing.md
│   │       └── java-lang.md
│   ├── review/
│   │   ├── SKILL.md                        # review loop + Iron Law; spawns auditors; pairs with gate-done.sh
│   │   └── references/
│   │       └── test-matrix.md
│   └── capture-learnings/
│       └── SKILL.md
│
├── hooks/
│   └── hooks.json                          # hook manifest [06]
│
├── scripts/                                # hook scripts [06]
│   ├── bootstrap.sh                        # SessionStart
│   ├── inject-phase.sh                     # UserPromptSubmit
│   ├── gate-write.sh                       # PreToolUse (action gate)
│   ├── format-java.sh                      # PostToolUse
│   ├── gate-done.sh                        # Stop (completion gate)
│   ├── verify-subagent.sh                  # SubagentStop
│   ├── persist-state.sh                    # PreCompact
│   └── inject-learnings.sh                 # helper (called by bootstrap.sh + inject-phase.sh)
│
├── bin/
│   ├── claudehut-init                      # deterministic project-plane generator (renders memory templates + stack-gated rules + @import) [05/07]
│   ├── claudehut-state                     # state writer [01 §4]
│   ├── claudehut-worktree                  # worktree lifecycle helper: status/check-disjoint/reconcile/sweep; scope-guarded to .claude/worktrees/ [11 §6]
│   └── kafka-mcp                           # custom Kafka MCP server [08]
│
├── templates/
│   ├── rules/                              # rule templates (tech-stack domains) — generated into project by claudehut-init, stack-gated [05]
│   │   ├── project-structure.md            # always-on (project-identity, templated)
│   │   ├── vocabulary.md                   # always-on (project-identity, templated)
│   │   ├── architecture/                   # package-layout, hexagonal, ddd, cqrs, adr-format
│   │   ├── coding/                         # naming, exception, null-safety, optional-stream, immutability, records-sealed, logging-mdc
│   │   ├── framework/                      # spring-mvc, webflux, jpa, r2dbc, kafka-{consumer,producer}, rabbitmq, nats, redis, jackson, mapstruct, flyway-naming, migration-safety, lombok-{annotations,builder,jpa-safety}  (stack: tagged)
│   │   ├── performance/                    # n-plus-one, indexing, connection-pool, caching, backpressure
│   │   ├── security/                       # spring-security, owasp-top10, input-validation, deserialization, secret-mgmt, actuator
│   │   └── testing/                        # junit5, mockito, given-when-then, tdd-cycle, testcontainers, wiremock, stepverifier, coverage
│   ├── MEMORY.md.tmpl                      # memory templates [07] — committed index
│   ├── PROJECT.md.tmpl
│   ├── LANGUAGE.md.tmpl
│   ├── architecture.md.tmpl
│   ├── reuse-index.json.tmpl
│   └── mcp-recommendations.md             # MCP suggestion catalog read by claudehut-init [08]
```

### Project plane — `${CLAUDE_PROJECT_DIR}/` (generated, lives with the repo)

The plugin never owns these files; `claudehut-init` creates them once, then hooks and skills maintain them.

```
<project>/
├── CLAUDE.md                               # PROJECT-OWNED; claudehut-init appends @import lines only
└── .claude/
    ├── rules/                              # generated from templates/rules/ by claudehut-init (recursive; stack-gated) [05]
    │   ├── project-structure.md            # always-on (no paths: filter)
    │   ├── vocabulary.md                   # always-on
    │   ├── architecture/                   # **/*.java + docs/adr/** scoped
    │   ├── coding/                         # **/*.java scoped (cross-cutting)
    │   ├── framework/                      # narrow per-type globs; only stack-matched files emitted
    │   ├── performance/                    # repo/migration/yaml/handler scoped
    │   ├── security/                       # SecurityConfig/controller/yaml scoped
    │   └── testing/                        # **/*Test.java, **/*IT.java scoped
    └── claudehut/                          # generated memory and state [07]
        ├── MEMORY.md                       # committed memory index — always-loaded via @import (07 §1.2)
        ├── PROJECT.md                      # always-loaded (@import)
        ├── LANGUAGE.md                     # always-loaded (@import)
        ├── architecture.md                 # on-demand (NOT @import-ed) — 07 §1.2
        ├── reuse-index.json
        ├── learnings.jsonl
        ├── state/                          # per-session phase-state files (written only by bin/claudehut-state)
        │   └── <session_id>.json           # one per session/task; gitignored, ephemeral (01 §4.1)
        └── tasks/                          # one dir per task (NNNN-<slug>/) — all task artifacts in one place
            ├── reuse-scan.md               # Discover: reuse-scan artifact (P4)
            ├── spec.md                     # Spec phase: implementation spec (subsumes ADR)
            ├── plan.md                     # Plan phase: T-xxx breakdown (durable source of truth)
            └── review.md                   # Review phase: auditor findings + test evidence + verdict
```

The boundary is absolute: nothing under `${CLAUDE_PLUGIN_ROOT}` is written at runtime; nothing under `<project>/.claude/` is shipped by the plugin.

---

## 2. plugin.json (annotated)

`plugin.json` is the only file that lives in `.claude-plugin/`. All component directories (`agents/`, `skills/`, `hooks/`, `scripts/`, `bin/`, `templates/`) are at the plugin root, never inside `.claude-plugin/`.

```json
{
  "name": "claudehut",
  "displayName": "ClaudeHut",
  "version": "1.0.0",
  "description": "7-phase agentic workflow for Java/Spring Boot backends (over a pre-indexed codebase): discover → brainstorm → spec → plan → implement → review → learn.",
  "author": {
    "name": "ClaudeHut Authors",
    "email": "plugins@claudehut.dev",
    "url": "https://claudehut.dev"
  },
  "homepage": "https://claudehut.dev",
  "repository": "https://github.com/claudehut/claudehut",
  "license": "MIT",
  "keywords": ["java", "spring-boot", "agentic-workflow", "tdd", "kafka", "jpa", "reactive"],
  "defaultEnabled": true

  // No "agents", "skills", or "hooks" keys. The standard agents/, skills/, and
  // hooks/hooks.json locations are AUTO-DISCOVERED. Re-declaring a default location
  // breaks the runtime `--plugin-dir` load ("agents: Invalid input" for a string
  // agents value; "Duplicate hooks file detected" for hooks/hooks.json) — the
  // manifest must name only NON-default locations. Verified via system/init
  // plugin_errors (a clean load shows claudehut in plugins[] with no errors).
  // No "mcpServers" and no "userConfig": ClaudeHut ships NO active MCP config —
  // a plugin's .mcp.json servers auto-connect (no native per-server "suggest" API),
  // so claudehut-init reads templates/mcp-recommendations.md and emits
  // `claude mcp add --scope project …` lines the developer chooses to run. [08]
}
```

**Key annotation notes:**

- **The manifest declares no component-directory keys.** ClaudeHut's components live in the standard locations (`agents/`, `skills/`, `hooks/hooks.json`), which Claude Code **auto-discovers**. Re-declaring them is not just redundant — it **fails the runtime `--plugin-dir` load**: a string `"agents": "./agents"` is rejected (`agents: Invalid input`), and `"hooks": "./hooks/hooks.json"` collides with the auto-loaded standard file (`Duplicate hooks file detected`). The component keys are reserved for *additional, non-default* locations only. (This was a real load-blocking defect caught by the eval load-probe; `claude plugin validate` does not catch it because it validates `marketplace.json`, not the runtime manifest schema. The authoritative check is `claude -p --output-format stream-json` → `system/init.plugin_errors`.)
- ClaudeHut declares **no `mcpServers` and no `userConfig`**. A plugin's `.mcp.json` servers auto-connect when the plugin is enabled (there is no native opt-in per server), which would force DB/Kafka/GitHub MCPs onto every project. Instead the plugin ships nothing and `claudehut-init` *recommends* servers per detected stack — three buckets (tech-stack, memory, research) — via `claude mcp add --scope project …` (catalog: `templates/mcp-recommendations.md`). The developer supplies their own connection strings/tokens, which Claude Code stores; the plugin never holds credentials. See [08](./08-mcp-integration.md).
- ClaudeHut declares **no `dependencies`**. The native `dependencies` field is for plugin-to-plugin dependencies, and ClaudeHut depends on no other plugin. The external CLI tools it uses — `google-java-format` (invoked by `format-java.sh`) and `jq` (used by the hook scripts) — are probed on `PATH` at runtime; the scripts fail open (exit 0) and warn if either is absent (see [06 §5](./06-hooks.md#5-failure-modes-and-escape-hatches)). They are intentionally not modelled as manifest dependencies because the native field does not represent external binaries.
- There is no `settings.json` at the plugin root. The native plugin `settings.json` only honours `agent` and `subagentStatusLine`; neither is overridden by ClaudeHut.

---

## 3. marketplace.json

`marketplace.json` lives alongside `plugin.json` in `.claude-plugin/` of the marketplace repository. It lists ClaudeHut as a distributable plugin.

```json
{
  "name": "claudehut-marketplace",
  "owner": {
    "name": "ClaudeHut Authors"
  },
  "plugins": [
    {
      "name": "claudehut",
      "displayName": "ClaudeHut",
      "description": "7-phase agentic workflow for Java/Spring Boot backends. Enforces discover → brainstorm → spec → plan → implement → review → learn (over a pre-indexed codebase) with Iron-Law skills, tier-aware action gates, and per-project memory.",
      "source": {
        "source": "github",
        "repo": "claudehut/claudehut"
      },
      "keywords": ["java", "spring-boot", "agentic-workflow", "tdd"],
      "version": "1.0.0"
    }
  ]
}
```

For local development or self-hosted distribution, `source` may instead be a relative path (`"./"`), pointing to the plugin root directory on disk.

---

## 4. File-by-file map

Every file in the static plugin plane, with its type, purpose, and the document that specifies it.

| Path | Type | Purpose | Spec |
|------|------|---------|------|
| `.claude-plugin/plugin.json` | Manifest | Plugin identity + metadata only — components (`agents/`, `skills/`, `hooks/`) auto-discovered; no `mcpServers`/`userConfig` (§2) | §2 this doc |
| `.claude-plugin/marketplace.json` | Manifest | Marketplace distribution listing | §3 this doc |
| **Agents** | | | |
| `agents/claudehut-explorer.md` | Agent | Read-only codebase query agent (**Discover**) | [03](./03-agents.md#claudehut-explorer) |
| `agents/claudehut-brainstormer.md` | Agent | Generates ≥2 generic approaches, consumes Discover output (Brainstorm) | [03](./03-agents.md#claudehut-brainstormer) |
| `agents/claudehut-reuse-scanner.md` | Agent | Enforces reuse-first, produces reuse-scan artifact (**Discover**) | [03](./03-agents.md#claudehut-reuse-scanner) |
| `agents/claudehut-planner.md` | Agent | Writes executable plan file (Plan) | [03](./03-agents.md#claudehut-planner) |
| `agents/claudehut-implementer.md` | Agent | Executes plan test-first in worktree (Implement); branches from `origin/HEAD`; commit-before-DONE contract; returns `DONE (branch, commit)`; BLOCKED-immediately rule | [03](./03-agents.md#claudehut-implementer) |
| `agents/claudehut-test-runner.md` | Agent | Runs suite, diagnoses failures (Review) | [03](./03-agents.md#claudehut-test-runner) |
| `agents/claudehut-reviewer.md` | Agent | General code review (Review) | [03](./03-agents.md#claudehut-reviewer) |
| `agents/claudehut-security-auditor.md` | Agent | OWASP/JWT/authn security review (Review) | [03](./03-agents.md#claudehut-security-auditor) |
| `agents/claudehut-perf-reviewer.md` | Agent | JVM/N+1/blocking perf review (Review) | [03](./03-agents.md#claudehut-perf-reviewer) |
| `agents/claudehut-db-reviewer.md` | Agent | JPA mapping/migration correctness (Review) | [03](./03-agents.md#claudehut-db-reviewer) |
| `agents/claudehut-learner.md` | Agent | Persists learnings + updates reuse-index (Learn) | [03](./03-agents.md#claudehut-learner) |
| **Skills — orchestration** | | | |
| `skills/claudehut-workflow/SKILL.md` | Skill | Orchestrator; injected at SessionStart | [04](./04-skills.md#claudehut-workflow) |
| `skills/claudehut-init/SKILL.md` | Skill | Bootstrap command `/claudehut:init` | [04](./04-skills.md#claudehut-init) |
| **Skills — phase** | | | |
| `skills/discover/SKILL.md` | Skill | Discover phase (NEW v0.4); dispatches explorer ∥ reuse-scanner in one message; Reuse Iron Law; every complexity tier | [04](./04-skills.md#discover) |
| `skills/brainstorm/SKILL.md` | Skill | Brainstorm phase; generic ideation; consumes Discover output; dispatches brainstormer; builds enforcement set | [04](./04-skills.md#brainstorm) |
| `skills/write-spec/SKILL.md` | Skill | Spec phase; writes the implementation spec from template; owns AskUserQuestion approval + set-spec | [04](./04-skills.md#write-spec) |
| `skills/write-spec/references/spec-template.md` | Reference | Spec template (spec-kit/EARS/MADR/Google synthesis); right-sized by task type | [11](./11-execution-model-and-artifacts.md) |
| `skills/write-plan/SKILL.md` | Skill | Plan phase; dispatches planner via Agent tool; owns approval gate + set-plan + TaskCreate mirror | [04](./04-skills.md#write-plan) |
| `skills/write-plan/references/plan-template.md` | Reference | Plan template (spec-kit tasks; T-xxx breakdown + decision summary §1) | [11](./11-execution-model-and-artifacts.md) |
| `skills/implement/SKILL.md` | Skill | Implement Iron Law; test-first enforcement; absorbs domain depth via references/ | [04](./04-skills.md#implement) |
| `skills/implement/references/web.md` | Reference | Spring MVC (controllers, exception handling, validation, REST conventions) | [04](./04-skills.md#implement) |
| `skills/implement/references/jpa.md` | Reference | JPA/Hibernate persistence playbook (fetch, N+1, equals/hashCode, locking) | [04](./04-skills.md#implement) |
| `skills/implement/references/reactive.md` | Reference | WebFlux + R2DBC + Reactor (operators, backpressure, error handling) | [04](./04-skills.md#implement) |
| `skills/implement/references/messaging.md` | Reference | Kafka / RabbitMQ / NATS (DLQ wiring, exactly-once semantics, consumer groups) | [04](./04-skills.md#implement) |
| `skills/implement/references/caching.md` | Reference | Redis + Spring Cache (cache-aside, TTL, eviction, serialization) | [04](./04-skills.md#implement) |
| `skills/implement/references/security.md` | Reference | Spring Security + OWASP (method security, JWT, CSRF, secret management) | [04](./04-skills.md#implement) |
| `skills/implement/references/persistence-ops.md` | Reference | Flyway migrations, indexing strategy, connection-pool sizing | [04](./04-skills.md#implement) |
| `skills/implement/references/testing.md` | Reference | JUnit 5 / Mockito / Testcontainers / WireMock / StepVerifier patterns | [04](./04-skills.md#implement) |
| `skills/implement/references/java-lang.md` | Reference | Java language features: records, sealed classes, Optional, MapStruct, Lombok | [04](./04-skills.md#implement) |
| `skills/review/SKILL.md` | Skill | Review loop + Iron Law; spawns auditors; folds in test-matrix guidance; pairs with gate-done.sh | [04](./04-skills.md#review) |
| `skills/review/references/test-matrix.md` | Reference | Slice-test decision matrix | [04](./04-skills.md#review) |
| `skills/capture-learnings/SKILL.md` | Skill | Learn Iron Law; forks to learner agent | [04](./04-skills.md#capture-learnings) |
| **Hooks** | | | |
| `hooks/hooks.json` | Hook manifest | Wires all 7 hook events to scripts | [06](./06-hooks.md#2-hooksjson-the-manifest) |
| `scripts/bootstrap.sh` | Hook script | SessionStart: inject orchestrator + learnings | [06](./06-hooks.md#bootstrapsh--sessionstart) |
| `scripts/inject-phase.sh` | Hook script | UserPromptSubmit: re-anchor phase + targeted learnings | [06](./06-hooks.md#inject-phasesh--userpromptsubmit) |
| `scripts/gate-write.sh` | Hook script | PreToolUse: block writes without reuse-scan + plan | [06](./06-hooks.md#gate-writesh--pretooluse-action-gate) |
| `scripts/format-java.sh` | Hook script | PostToolUse: auto-format `*.java` files (async) | [06](./06-hooks.md#format-javash--posttooluse) |
| `scripts/gate-done.sh` | Hook script | Stop: block completion before review-pass + learn (honors stop_hook_active cap) | [06](./06-hooks.md#gate-donesh--stop-completion-gate) |
| `scripts/verify-subagent.sh` | Hook script | SubagentStop: confirm subagent produced required artifact | [06](./06-hooks.md#verify-subagentsh--subagentstop) |
| `scripts/persist-state.sh` | Hook script | PreCompact: flush learnings/state before compaction | [06](./06-hooks.md#persist-statesh--precompact) |
| `scripts/inject-learnings.sh` | Helper script | Shared: rank + emit top-N learnings from `learnings.jsonl` | [06](./06-hooks.md) |
| **Bin** | | | |
| `bin/claudehut-init` | CLI binary | Deterministic project-plane generator: detects the stack (grep/sed on build files), renders the memory templates + stack-gated `.claude/rules/` tree into `.claude/claudehut/` + `.claude/rules/`, wires the `@import` slice; creates `tasks/` dir (one-per-task artifact home); idempotent (`--refresh`, never clobbers `learnings.jsonl`), `--detect` prints stack JSON. Invoked by the `claudehut-init` skill. | [05](./05-rules.md), [07 §3](./07-memory-architecture.md#3-bootstrapping-a-new-project) |
| `bin/claudehut-state` | CLI binary | Phase-state writer (takes `--session`); the only process that mutates the per-session `state/<session_id>.json` (atomic temp+rename) | [01 §4.1](./01-agentic-workflow.md#41-concurrency-and-worktree-isolation-collision-safe-state) |
| `bin/claudehut-worktree` | CLI binary | Worktree lifecycle helper for managed agent worktrees under `.claude/worktrees/`; subcommands: `status`, `check-disjoint` (safety gate for parallel dispatch), `reconcile` (serialized merge with conflict-abort + red-test rollback), `sweep` (clean+merged removal only); scope-guarded — cannot touch worktrees outside the managed root | [11 §6](./11-execution-model-and-artifacts.md#6-parallel-execution--worktree-lifecycle) |
| `bin/kafka-mcp` | MCP server | Custom Kafka MCP: topics/consumer-groups/offsets | [08](./08-mcp-integration.md) |
| **Templates** | | | |
| `templates/rules/project-structure.md` | Rule template | Always-on: module layout, package conventions (templated) | [05](./05-rules.md) |
| `templates/rules/vocabulary.md` | Rule template | Always-on: canonical term lock (templated) | [05](./05-rules.md) |
| `templates/rules/architecture/*.md` (5) | Rule templates | package-layout, hexagonal, ddd, cqrs, adr-format | [05 §4](./05-rules.md#4-the-rule-set--organized-by-tech-stack-domain) |
| `templates/rules/coding/*.md` (7) | Rule templates | naming, exception, null-safety, optional-stream, immutability, records-sealed, logging-mdc | [05 §4](./05-rules.md#4-the-rule-set--organized-by-tech-stack-domain) |
| `templates/rules/framework/*.md` (16) | Rule templates | spring-mvc, webflux, jpa, r2dbc, kafka-{consumer,producer}, rabbitmq, nats, redis, jackson, mapstruct, flyway-naming, migration-safety, lombok-{annotations,builder,jpa-safety} — `stack:` tagged | [05 §4](./05-rules.md#4-the-rule-set--organized-by-tech-stack-domain) |
| `templates/rules/performance/*.md` (5) | Rule templates | n-plus-one, indexing, connection-pool, caching, backpressure | [05 §4](./05-rules.md#4-the-rule-set--organized-by-tech-stack-domain) |
| `templates/rules/security/*.md` (6) | Rule templates | spring-security, owasp-top10, input-validation, deserialization, secret-mgmt, actuator | [05 §4](./05-rules.md#4-the-rule-set--organized-by-tech-stack-domain) |
| `templates/rules/testing/*.md` (8) | Rule templates | junit5, mockito, given-when-then, tdd-cycle, testcontainers, wiremock, stepverifier, coverage | [05 §4](./05-rules.md#4-the-rule-set--organized-by-tech-stack-domain) |
| `templates/MEMORY.md.tmpl` | Memory template | Scaffold for the committed always-loaded index `MEMORY.md` | [07 §1.2](./07-memory-architecture.md#12-cost-aware-context-loading) |
| `templates/PROJECT.md.tmpl` | Memory template | Scaffold for generated `PROJECT.md` | [07](./07-memory-architecture.md) |
| `templates/LANGUAGE.md.tmpl` | Memory template | Scaffold for generated `LANGUAGE.md` | [07](./07-memory-architecture.md) |
| `templates/architecture.md.tmpl` | Memory template | Scaffold for generated `architecture.md` | [07](./07-memory-architecture.md) |
| `templates/reuse-index.json.tmpl` | Memory template | Empty reuse-index scaffold | [07](./07-memory-architecture.md) |
| **MCP config** | | | |
| `templates/mcp-recommendations.md` | MCP catalog | Per-stack `claude mcp add` suggestions (tech-stack/memory/research) read by `claudehut-init`; the plugin ships no active `.mcp.json` | [08](./08-mcp-integration.md) |

---

## 5. Naming & namespacing conventions

**Agent names** follow `claudehut-<role>` in kebab-case (e.g. `claudehut-security-auditor`). The `claudehut-` prefix is mandatory — it prevents collisions with user agents and makes delegation intent unambiguous in Task-tool dispatch logs.

**Skill names** are kebab-case without a prefix (e.g. `brainstorm`, `implement`, `write-spec`). Each `skills/<name>/SKILL.md` becomes the slash command `/claudehut:<name>`, inheriting the `claudehut:` namespace from `plugin.json`'s `name` field. A flat `commands/<name>.md` would also resolve to `/claudehut:<name>` but is not used here — skills are preferred because they support `description`-based auto-triggering.

**Rule file names** inside `templates/rules/` match their generated counterparts in `<project>/.claude/rules/` exactly, preserving the domain subpath (e.g. `framework/jpa.md` → `.claude/rules/framework/jpa.md`; native `.claude/rules/` is discovered recursively). Generated rule files carry a provenance comment on their first line:

```
<!-- ClaudeHut rule template — generated into .claude/rules/<domain>/<name>.md by claudehut-init. Reused & enhanced from committed rules/<domain>/<name>.md. -->
```

The comment records the file's origin; on re-`init` a hand-edited rule is treated as **authoritative** (init diffs and asks before overwriting — see [05 §3](./05-rules.md#3-templates--generated-rules-the-adaptation-step)), so the layer is plugin-seeded but developer-owned.

**Memory template files** use `.tmpl` extension to distinguish them from live memory files. `claudehut-init` renders them (filling in detected stack values) and writes the rendered output to `<project>/.claude/claudehut/`.

**MCP servers** are not shipped by the plugin. `claudehut-init` reads `templates/mcp-recommendations.md` and emits `claude mcp add --scope project <name> …` suggestions per detected stack; the developer runs the ones they want, and those servers land in the *project's* own `.mcp.json` (not the plugin's). See [08](./08-mcp-integration.md).

---

## 6. Native constraints honored

Each native Claude Code rule and how the layout satisfies it:

- **Only `plugin.json` (and `marketplace.json`) live in `.claude-plugin/`.** All component directories (`agents/`, `skills/`, `hooks/`, `scripts/`, `bin/`, `templates/`) are at the plugin root. Putting anything else in `.claude-plugin/` would violate the native plugin contract.

- **A plugin cannot ship `.claude/rules/` or `CLAUDE.md`.** The native plugin component slot list (`agents/`, `skills/`, `commands/`, `hooks/`, `output-styles/`, plus the `.mcp.json` and `.lsp.json` files) has no `rules/` entry, and path-scoped auto-loading only works from `${CLAUDE_PROJECT_DIR}/.claude/rules/`. ClaudeHut therefore ships rule *templates* under `templates/rules/` and `claudehut-init` writes the live rules into the project. The project's `CLAUDE.md` is never shipped by the plugin; `claudehut-init` only appends `@import` lines to the already-existing project file.

- **`${CLAUDE_PLUGIN_ROOT}` is replaced on update — never write state there.** All runtime state (the per-session `state/<session_id>.json`, `learnings.jsonl`, and per-task artifacts under `tasks/`) lives in `${CLAUDE_PROJECT_DIR}/.claude/claudehut/`, which survives plugin updates. `${CLAUDE_PLUGIN_DATA}` is the native per-machine persistence slot and remains available for any future machine-global cache needs, but the current design requires none — per-project isolation is achieved by keying everything to `CLAUDE_PROJECT_DIR`.

- **`bin/claudehut-state` is the sole writer of the per-session state file.** Hook scripts read `state/<session_id>.json` but never write it; skills can instruct the agent to run `claudehut-state --session ${CLAUDE_SESSION_ID} …`, but the binary is the single authoritative writer (atomic temp+rename). Its subcommands match the authoritative schema in [01 §4](./01-agentic-workflow.md#4-the-phase-state-machine): `set-phase`, `set-reuse-scan`, `set-enforcement`, `set-spec`, `set-plan`, `set-review`, `set-outstanding`, `set-bypass`, `set-complexity` (all take `--session`). The per-session keying prevents concurrent-task collisions ([01 §4.1](./01-agentic-workflow.md#41-concurrency-and-worktree-isolation-collision-safe-state)); this preserves the clean hook-reads / command-writes separation ([06](./06-hooks.md#1-the-hook-io-protocol-what-we-rely-on)).

- **`"agents"` replaces; `"skills"` adds.** Setting `"agents": "./agents"` in `plugin.json` replaces Claude Code's default agent discovery with ClaudeHut's 11 specialists. This is deliberate: the specialists' `description` fields are tuned for the workflow's delegation logic, and mixing in default agents would introduce agents that do not understand the phase protocol. `"skills": "./skills"` additive behavior is correct — ClaudeHut's 9 phase/orchestration skills should coexist with any project or user skills.

- **Plugin-shipped agents ignore `hooks`, `mcpServers`, and `permissionMode` frontmatter.** The agent `.md` files therefore do not declare these. MCP access is **opt-in per project** (the plugin ships no `.mcp.json`; `claudehut-init` suggests `claude mcp add` commands — see [08](./08-mcp-integration.md)); hook behavior is governed by the plugin-level `hooks/hooks.json`. Any such frontmatter in an agent file would be silently ignored and should be omitted to avoid misleading readers.

- **`plugin.json`'s `settings.json` plugin-root file only honors `agent` and `subagentStatusLine`.** ClaudeHut does not ship a plugin-root `settings.json` because it does not override the default agent or customize the status line. If future versions need to set a workflow-aware status line, that file is the correct place.

- **The plugin holds no secrets.** ClaudeHut ships no `userConfig` and no `.mcp.json`, so no connection strings or tokens pass through the plugin. When a developer opts into a recommended MCP server via `claude mcp add`, the credentials live in the *project's* own `.mcp.json` (or Claude Code's store) and are owned by the developer, not the plugin. The hook scripts never read credentials.

---

**Prev:** [← 08. MCP Integration](./08-mcp-integration.md) · **Next:** [10. Build Roadmap →](./10-build-roadmap.md)
