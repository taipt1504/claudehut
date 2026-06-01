# Changelog

All notable changes to ClaudeHut are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/); versioning is [SemVer](https://semver.org/)
(pre-1.0: the project stays in the `0.1.x` line while the schema stabilizes, so feature
work lands as patch releases until `0.2.0` cuts the first separate minor).

## [0.1.2] — 2026-06-01

### Changed
- **Build phase now dispatches native `Task(claudehut:claudehut-builder)` subagents** (one per
  task, in a single message) instead of the headless `claude --print &` pool — so build workers
  appear in the agent tracker like every other phase (observable/controllable status; fixes the
  "opaque 33-min background shell, no per-worker status" report). New `prep-parallel-group.sh`
  sets up one git worktree + one self-contained prompt per task and emits a manifest; builders
  work via **absolute paths / `git -C`** (a subagent's cwd doesn't persist); `merge-parallel-group.sh`
  merges passing branches; `--cleanup` tears worktrees down. Mechanics validated by a worktree
  spike; `prep` is producer-tested (tests/integration + L16). **Trade-off (opted in):** native
  Task workers run in-session, so the per-worker pre-launch **budget gate no longer applies** on
  this path — bound runaway builders via the tracker + `TASK_TIMEOUT`. The legacy
  `run-parallel-group.sh` pool (with the budget gate, not tracker-visible) is kept as a fallback.

## [0.1.1] — 2026-06-01

### Added
- **Adaptive-depth routing** (Phase 0.5): a deterministic, conservative triage step
  (`/claudehut:route`) records a `quick` (build + verify) or `full` (six-phase) profile in
  `.claudehut/state/route-<task>.json`; the phase gate walks only the routed phases.
- **Memory & retrieval reinforcement**: JIT top-K relevance retrieval per task
  (`0.45·path + 0.30·tag + 0.10·title + 0.15·usefulness_prior`) replacing the static
  learnings dump; outcome-signal usefulness prior (Laplace); optional memory-MCP read path;
  meta-learning rule proposals (human-approval, never auto-edits `rules/`).
- **Cost telemetry + budget control**: per-worker `.cost` sidecars + a per-run
  `run-summary.jsonl`; a worker-pool budget gate (skip-not-kill, exit 3, `budget-breach.json`);
  per-role model tiers (`agents.builder_model`, `agents.reviewer_models`).
- **Native-primitive polish**: `nats` + `rabbitmq` framework rules (mirroring kafka); a
  runtime path→rule resolver test; a guardrail floor-subset invariant; a logical
  core/spring/messaging/quality module-partition manifest (`modularization/modules.json`)
  with a no-pack→pack coupling proof.
- **Programmatic Agent-SDK orchestrator** (`sdk/`, optional/experimental): a deterministic
  JS control loop wrapping the bash runtime; persona→`allowedTools`/`permissionMode` mapping;
  measured parity vs the bash pipeline (trivial-sum-bug, k=3: pass@1 1.0/1.0, ~half cost,
  ~half wall, 0/3 budget breaches). The Claude Code plugin path remains primary.
- **Eval harness** (`evals/`): deterministic held-out-oracle scorer, opt-in real-Claude
  runner (`run.sh`, `--max-budget-usd`-capped, `baseline|claudehut|sdk` arms),
  `compare.sh --variance`.
- **Detailed usage guide** (`docs/GUIDE.md`); README updated for all of the above.

### Changed
- Relaxed the absolute "even a 1% chance → you MUST invoke" skill mandate to a
  **clear-domain-match** rule (it over-invoked — a Controller task could fire `kafka-consumer`);
  skill descriptions trimmed trigger-first to ≤300 chars.
- Skills: 28 → 31; rules: 42 → 47 (framework 11 → 16); test suite: 222 → **479** deterministic
  assertions across ~27 sections (L1–L27), still model-free.

### Fixed
- Eval harness: the plugin's MCP servers (`context7`/`github`/`memory`/`postgres`/
  `sequential-thinking`) hang on startup in a headless run — `run.sh` now neutralizes MCP so
  both eval arms compare fairly.
- Phase-3 dispatch namespacing (`claudehut:claudehut-<agent>`), Phase-4 writer/reader key
  drift, the route-aware build+loop editable window, and the SDK orchestrator's phase→skill
  mapping (`loop`→`verify-review`) + route-sequence walk.

## [0.1.0] — 2026-05

### Added
- MVP: artifact-derived six-phase workflow (Brainstorm → Spec → Plan → Build → Loop → Learn);
  17 agents, 28 skills, 42 rules, 8 hooks; reuse-detection; stack-aware native-rule loading;
  project-scoped memory; parallel reviewer subagents; strict-TDD enforcement; bash-3.2 test
  harness; single-plugin marketplace.

[0.1.2]: https://github.com/taipt1504/claudehut/releases/tag/v0.1.2
[0.1.1]: https://github.com/taipt1504/claudehut/releases/tag/v0.1.1
[0.1.0]: https://github.com/taipt1504/claudehut/releases/tag/v0.1.0
