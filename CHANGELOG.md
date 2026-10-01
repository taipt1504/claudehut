# Changelog

## 0.12.0 — 2026-10-01

v0.12 stops forcing a seven-phase workflow on every request. Hooks only advise, a router picks the route, and a
deterministic index and hub replace re-exploring the codebase. Design: [`.claude/docs/v0.12/`](.claude/docs/v0.12/README.md).
Measurements: [`evals/results/v012/README.md`](evals/results/v012/README.md).

### M1 — Advisory hooks, task state schema 2
- Every hook only adds context. 0 `decision`, `permissionDecision` or `updatedInput` across all fixtures and replays,
  and every output passes `jq -s 'length<=1'`. The write gate, the `Stop` gate (`gate-done.sh`), `record-skill*`
  and out-of-workflow denies are removed.
- State is one `tasks/<id>/task.json` per task (`schema: 2`), written only by `claudehut-state`. Files without
  `schema: 2` count as no task.
- `bootstrap.sh` no longer spawns `claude plugin list`. Plane maintenance moved to the async `maintain.sh`.
- `hooks.json` ends at 13 handlers and 16 entries. `evals/hook-tests.sh` replaces `gate-tests.sh`, and
  `evals/hook-bench.sh` reports latency without gating it.

### M2 — Router and digest
- Three routes: `direct`, `light` and `full`, plus `ask`. The digest is 2,400 B, down from 4,331 B in v0.11.
  "skip workflow" never opens a task.
- On 22 labelled ewallet prompts with sonnet, the v0.12 digest scores 18/22 against 10/22 for the v0.11 digest,
  with 0 full→direct and 0 direct/light→full (v0.11: 6).

### M3 — Artifact standards and doclint
- `scripts/doclint.sh` checks the structure of spec, plan, brainstorm, plan-review and task.md, plus word
  budgets. Budgets are advisory and scale ×1.4 for `vi`. The check runs at `set-spec` and `set-plan` and inside
  the planner, through `doclint-advise.sh`.
- A replay over 244 v0.11 task dirs catches all three targets: va-ms 0008 (L4, over budget), va-ms 0024 (L2,
  AMENDMENT) and party-ms 0002 (L6, a 2,685-character table cell).

### M4 — Review from the diff
- `scripts/review-pack.sh` picks lanes from the changed paths and hunks. The roster went from 7 to 5 review
  agents (12 agents in total). No review agent carries `mcp__*` or `ultrathink` any more. The reviewer always
  runs and escalates any lane that did not run or ran on only part of the diff.
- Replay on 22 stratified tasks: waves with 4 or more lanes fell from 10/22 (45.5%) to 5/22 (22.7%), and
  dispatches from 81 to 67. No small or medium task reaches 4 lanes, and every large task does. Projected onto
  the 52 v0.11 review waves, the rate is 21–33%, so the ≤25% target is not proven; it will be re-measured on
  real waves after release.
- On the light route, dispatches rise from 2 to 5, because the reviewer always runs; this is accepted as a
  floor cost.
- 73.6% of the 72 in-diff MED+ findings land in a lane or with the reviewer floor. All 19 findings that only an
  escalation can catch have a fixture.

### M5 — Codebase index and bounded memory
- `bin/claudehut-index` runs a deterministic extractor (python3 stdlib, 24 rules) with these commands: `status`,
  `brief`, `find`, `svc`, `links`, `update` and `memory`. The index is stamped with the commit it was built
  from. Optional git hooks refresh it after pull, rebase or checkout.
- On va-ms: 149 components, 149 of them pass `test -f`, and read commands change no mtime.
- MEMORY.md now has a generated part of at most 2 KB. party-ms went from 105,333 B to 1,207 B, and a new plane
  starts at 831 B.
- Init asks for the language (`vi` or `en`). SessionStart is 3,556 B at worst, against a target of ≤4,000 B and
  8,999 B median in v0.11.
- `merge-learnings.sh` normalizes the learning body, gates entries shorter than 20 characters, fuzzy-dedups
  near-identical entries and adds `--repair`.

### M6 — Microservice knowledge hub
- `claudehut-init --hub/--mode microservice` creates a local hub repo with `git init` and no remote.
  `hub-sync` and `hub-scan` (read-only) link services by http, kafka, lib and shared-db edges, with evidence for
  each edge.
- The hub also writes a service-level understand-anything graph: 0 `validateGraph` issues, and the dashboard
  returns HTTP 200.
- ewallet clone: 5 services, 22 edges, 0 of 71 evidence paths missing.
- `hint-explore.sh` points a cross-service Read or Grep to the index. p95 is 23.2 ms on an idle machine.
- Fleet learnings live in `<hub>/fleet-learnings.jsonl` and are injected at ×0.7 confidence.

### M7 — Migration and release
- `bin/claudehut-migrate --workspace --hub --language [--git-hooks safe|none] (--dry-run | --apply | --restore)`
  migrates a v0.11 workspace. It backs every repo up first and verifies each tar listing, never edits
  `.gitignore`, and never commits. `evals/migrate-tests.sh` covers it.
- Dry-run on the 13-service ewallet workspace: 0 bytes written to it. Rehearsed on a copy, a re-apply changes
  nothing, and restore gives back every backed-up file byte for byte.
- `claudehut-init --no-extras` never adds `.worktreeinclude` or the marketplace entry. The unattended
  `--refresh-rules` behaves the same way.
- Fixes found by the migration dry-run:
  - `merge-learnings.sh` read a body under `summary` as empty and moved all 7 aml-service entries to rejected.
  - A date-only `ts` read as epoch, so prune would have deleted those entries. `--repair` now also gives a
    hand-written entry what a new one gets: an id, confidence 0.6 and hits 1.
  - `memory.py` rewrote MEMORY.md with mode 0600.

### Deprecated, kept for one release
- The `set-bypass`, `mark-skill`, `pause`, `rename` and `route` verbs are no-ops with a notice, and
  `set-complexity` maps onto the route. All of them are candidates for deletion in 0.13, once no cached v0.11
  skill text can call them.
- `CLAUDEHUT_FEDERATION_ROOT` is still accepted as an alias for the hub.

### Measured after release
These need real sessions on v0.12 and are not claimed here:
- Explorer calls and cross-service reads (07 AC-14).
- The language line in dispatch prompts (04 AC15).
- Review fan-out on real waves.
