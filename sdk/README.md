# ClaudeHut Agent-SDK orchestrator (Phase 7.1)

A programmatic orchestrator for the ClaudeHut pipeline, built on the
[Claude Agent SDK](https://platform.claude.com/docs/en/agent-sdk/typescript). It
replaces the model-interpreted, prose-driven main-thread orchestration with a
**deterministic JS control loop** — phase sequencing, loop retry cap, and budget
gate are code, not instructions the model has to follow. That is the robustness
goal of Phase 7.1: *control flow no longer depends on model cooperation.*

## WRAP, not replace

The plugin remains a Claude Code plugin; this is an **optional** programmatic entry
point that reuses the existing runtime behind the SDK:

| Concern | Reused from | Why |
|---|---|---|
| Phase derivation | `bin/claudehut-state phase` | one artifact-state machine (no drift) |
| Phase prompt | `skills/<phase>/scripts/dispatch-prompt.sh` | keeps Phase-4 JIT retrieval + artifact injection (the dynamic enrichment `context:fork` can't carry — see 6.4) |
| Build workers | `skills/build/scripts/run-parallel-group.sh` | bash workers behind the SDK (per the 7.1 spec) + Phase-5 telemetry/budget |
| Subagent tools/perms | `sdk/agent-config.json` | the SDK ignores filesystem `allowed-tools`; subagents are declared programmatically |

## Files

- `gen-agent-config.sh` — regenerates `agent-config.json` from `agents/*.md`
  frontmatter (the persona → `{description, tools, model, promptSource}` mapping +
  session permissionMode + orchestrator allowedTools). Idempotent.
- `agent-config.json` — the generated manifest (committed; CI asserts it is fresh).
- `lib/control-flow.mjs` — pure, SDK-free decisions (phase→persona, permissions,
  retry cap, budget gate). Unit-tested.
- `orchestrator.mjs` — the SDK loop.
- `test/control-flow.test.mjs` — `node --test` unit tests for the pure layer.

## Run

```sh
cd sdk && npm install            # pulls @anthropic-ai/claude-agent-sdk
node orchestrator.mjs "Add a /health endpoint returning 200 OK"
```

Env: `CLAUDEHUT_LOOP_MAX_RETRIES` (default 3), `CLAUDEHUT_MAX_POOL_USD` (0 = unlimited;
exit 3 on breach).

## What is verified — and the one $ boundary

**Verified deterministically, no spend** (CI, `tests/run-all.sh` L26 + `npm test`):
the translation layer (every persona → a valid SDK agent def; least-privilege tools;
`Task`→`Agent`; only the driver dispatches); the pure control flow (phase table, retry
cap, budget gate); a **stub-deps loop smoke** that drives route→…→build→loop→learn→done
with correct per-phase routing + budget/retry halts (no SDK/model/$); and an
**end-to-end envelope smoke** where `main()` runs against an uninitialized project and
emits a `score.sh`-gradeable envelope with no model call. The parity *harness* is wired
and verified $-free: `run.sh sdk` → orchestrator → envelope → `score.sh` → `compare.sh
--variance`.

**Blocked on authorized spend** (NOT deferred — the capability is built, wired, and
unit-tested; only its *quality measurement* needs money). The live run is one command
per arm:

```sh
cd sdk && npm install                                  # one-time
CLAUDEHUT_EVAL_BUDGET=2 evals/run.sh trivial-sum-bug sdk        # ×k (repeat to accumulate rows)
CLAUDEHUT_EVAL_BUDGET=2 evals/run.sh trivial-sum-bug claudehut  # ×k  (the bash baseline arm)
evals/compare.sh --variance evals/results/sdk.jsonl            # mean + variance per (task,mode)
```

7.1's acceptance test is *"≥ parity at lower variance"* vs the bash orchestration:
k ≥ 3 runs per arm. Cost ≈ $15–25 (2 eval tasks × 2 arms × k3 ≈ 12 runs at ~$1–2).
Until authorized, the orchestrator is *built, wired, and unit-tested*, with live
parity unmeasured.
