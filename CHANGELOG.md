# Changelog

## Unreleased — 0.20 M1 (kernel K1/K2 in Python)

- **State writer ported to the Python kernel** (docs/v0.20 04 §7, strangler step 1): `bin/claudehut-state` is a shim
  that runs `claudehut_kernel/state.py`; the CLI contract (verbs, messages, exit codes, task.json shape) is unchanged.
  The 0.12 bash writer stays at `scripts/legacy/claudehut-state.sh` for one release: `CLAUDEHUT_STATE_IMPL=bash`, a
  python3 that is missing or older than 3.8, and the read-only `cost-report` run it. Gates run in-process; a gate
  that raises is recorded as `gate.skipped` and never refuses. The plane lock interoperates with the bash writer
  (flock on `state/.state.lock.flock` and the mkdir lock).
- Tests: every suite runs under both writers (`CLAUDEHUT_STATE_IMPL=py|bash`, all green); `regress/state-diff-tests.sh`
  runs the same verb scripts through both and requires identical transcripts (exit codes, stdout, stderr, task.json,
  pointers, events); `regress/state-lock-tests.sh` pins the lock interleavings in-process.

## 0.12.8 — 2026-10-21

ADR K-18 (accepted): the writable plane moves out of `.claude/`. Claude Code treats `.claude/` as a protected
path: Write/Edit there prompts in `default`/`acceptEdits`, goes to the classifier in `auto`, and is **denied** in
`dontAsk` (headless runner, routines, `claude plugin eval`); `permissions.allow` does not lift it. Verified by the
`process/plane-write-probe` eval case. Path resolution only: no gate, hook or schema behaviour changes.

- **New layout `<repo>/.claudehut/`** (tasks, learnings, index, state, ledger, events; a hub keeps `<hub>/.claudehut/hub`).
  One rule, two twins: `scripts/lib/plane-path.sh` (bash) and `claudehut_kernel/plane.py` (Python; the index
  tools import it through `scripts/index/planepath.py`): `.claudehut/` if present, else a legacy
  `.claude/claudehut/`, else `.claudehut/`. Every hook, `claudehut-state`, `doclint`, the index/hub/memory tools
  and the index git hook resolve through it. Either inner hub spelling still names the hub root.
- **`claudehut-init`** creates `.claudehut/` on a fresh repo with its own `'*'` `.gitignore` (local by default,
  `shared:false`; the project `.gitignore` is still never edited) and wires `@.claudehut/…` imports. A repo that
  already has a legacy plane keeps it.
- **`bin/claudehut-migrate-plane --dry-run|--apply [REPO…]`** moves a legacy plane: `mv`, rewrites only the
  `@.claude/claudehut/` imports in CLAUDE.md, keeps a local plane local, re-installs the index git hooks. Never
  commits; refuses a repo with both layouts. Not run on any repo by this release (phase B).
- Skills say `<plane>/…`; SessionStart names the plane next to the State CLI line. Agents name both layouts.
- Tests: `evals/regress/plane-layout-tests.sh` (resolver parity, state CLI on both layouts, migrate, a grep guard
  against new hard-coded plane paths); init/hub fixtures that create a fresh plane now expect `.claudehut/`;
  every legacy-fixture suite stays green unchanged.

## 0.12.7 — 2026-10-21

Track Q of the 0.20 harness design (`.claude/docs/v0.20/`, 09 §2.1): small fixes for S1 problems, built as the
first modules of the Python kernel (ADR K-11, python3 stdlib, `scripts/kernel/`, shims `bin/claudehut-kernel`,
`bin/claudehut-verify`). No change to services or hub data (phase B).

- **Gate engine + task event log (K1/K2, ADR K-03/K-05).** Invariants are checked only at explicit transitions.
  Mode `CLAUDEHUT_GATE_MODE` > `topology.json .gates.mode` > `warn`: `warn` records and proceeds, `block` refuses
  (task.json byte-identical) unless `--override "<reason>"`. Every outcome is an event in
  `tasks/<id>/events.jsonl` (`gate.warned|blocked|overridden`, `review.verdict`, `task.ended`, `budget.exceeded`).
  python3 missing → the gate is skipped with a notice.
- **`end --status done` invariant (STA-1).** Done needs review `pass|capped`; after a pass, the verdict must still
  match: `set-review pass` stores a `review_binding` (content fingerprint of the change since the task base +
  spec/plan sha256). An edit after review is `tree-changed`; committing the reviewed change is not.
- **`claudehut-verify` (VER-1).** `claims` resolves every cited `path` / `path:line` (repo roots, project dir,
  unique suffix/basename, `.claude/` rules and skills; deleted-at-base files and URLs are not judged), `findings`
  (task.outstanding, `open` table rows), `verdict`. `set-review pass` runs claims + findings as a gate.
- **Host probe (ENV-1, ACI-2, ADR K-17).** maintain.sh (async) runs `claudehut-kernel probe` under a 2 s deadline:
  every foreign PreToolUse Bash hook is tested with synthetic payloads (cached a day per hook; disabled hooks never
  run; `CLAUDEHUT_PROBE_HOOKS=0` disables) and bootstrap.sh reads the result (`--cached`); a rewrite
  (`git status` → `rtk git status`) adds one advisory line; `state/env-profile.json` records it plus the auth mode
  (plan | api | bedrock | vertex | foundry). The implementer prompt now says: one simple command per Bash call,
  git by absolute path, Edit instead of `sed -i`.
- **Learning truth maintenance (KNW-2).** `claudehut-kernel learn retract <id> --reason R` / `learn verify <id> --by X`
  (plane or `--hub` store, merge-learnings' lock). Retracted entries are skipped by the injector, scoring and
  MEMORY counts. A fleet copy now needs `verified_by`; an unverified fleet lesson stays local
  (`fleet_held_unverified` in the merge report). The learner is told so.
- **Selftest canaries (VER-3).** `claudehut-kernel selftest` runs every hooks.json command with a synthetic payload
  (exit 0, ≤1 JSON object) plus 4 behavioural canaries (gate refuses, claims catches, failure recorder keeps exit
  code + stderr, probe answers); a dead control exits 1.
- **Budget overrun is an event (PLN-3).** A spec/plan/task over its doclint total budget records
  `budget.exceeded` and tells the model the overrun in percent; still never a refusal.
- **Eval harness (EVL-1).** `evals/run.sh`: the `.is_error // true` jq trap (every false read as true) is fixed;
  `--mode both` runs the no-plugin arm per trial; `--auth plan|api|auto` (plan = subscription login, no `--bare`;
  api = `--bare` + key); per-task `budget` file, default $12; budget/turn kills are `aborted` and not scored; rows
  carry `auth_mode`, `claude_version`, `env_profile`. `evals/summarize.sh` reports pass rate and Δ per task × auth.
- Tests: `evals/regress/verify-tests.sh` (53) and `eval-harness-tests.sh` (13) run inside hook-tests.sh;
  merge-learnings +1. Deterministic total 1654 → 1721. A fresh-context review of this change found 12 defects
  (fingerprint vs staging, probe on the sync path, crash read as refusal, retracted ignored by merge, …); all are
  fixed with regression tests (docs/v0.20/10-implementation-log.md).
- `claude plugin eval` suites under `evals/suites/` (process 2, decision 3, outcome 1) and `evals/plugin-eval.sh`
  (copies the plugin outside $HOME: sandboxed Bash cannot read it). M0 of the 0.20 roadmap; smoke-validated.

## 0.12.6 — 2026-10-04

Summer KB: opt in module docs a service does not depend on yet, so a fleet-wide rollout (DR, feature flags) can
ground every service before the dependency lands.

- **`--with <mod>[,<mod>…]` / `--without <mod>[,…]`** on `install_summer_kb.py`. The set is stored as
  `optInModules` in the consumer's `.summer-kb-meta.json`; every later run, the `--if-stale` one maintain.sh starts
  included, installs detected ∪ opt-in, so an opt-in doc is never removed as unused. A name the source KB has no doc
  for is an error (exit 2, `summer-kb: skip (error: unknown module …)`), checked before anything is written.
- The scoped `INDEX.md` lists opt-in docs, tags their rows `opt-in, not yet a dependency` and names the Gradle
  artifact to add.
- `ARTIFACT_TO_MODULE` maps `summer-dr-core` / `-autoconfigure` → `dr` and `summer-featureflag-core` /
  `-autoconfigure` → `featureflag` (both in `MODULE_ORDER`), so a `-core`-only consumer gets the doc too.
- maintain.sh is unchanged: it still compares stamps only (summerCommit, build-file mtime). The installer's own
  module-set check compares against the stamped union and opt-in set, so a second `--if-stale` is `up-to-date`
  (no refresh loop); stamps without `optInModules` stay current. The bundled snapshot has no `dr.md` /
  `featureflag.md`, so `--with dr` needs the sibling java-common-ms KB.
- migrate-tests §8 pins `--with`, `--if-stale` keeping it, `--without`, an unknown module, a `-core`-only consumer
  and the INDEX marker.

## 0.12.5 — 2026-10-02

Hub: a user decision can now close a link the hub cannot decide on its own.

- **`aliases.json` `"ignore"`.** Maps an env name, a topic, or `<svc>:<env|topic>` (one service only) to a
  reason, e.g. `{"ignore": {"aml-service:CLIENTS_COMPLIANCE_URL": "dead config: legacy compliance API"}}`. A
  matching HTTP client, Feign target, kafka consumer or producer row goes to `ignored` with reason
  `declared in aliases.json: <reason>` and its evidence line, instead of `unresolved` or an edge. An unscoped key
  applies to every service. Only a test/local-profile copy keeps its own reason. Every input row still ends in
  exactly one edge or bucket row. The `_note` in a fresh `aliases.json` documents the key.
- hub-tests §12 pins a scoped ignore (the same env in another service keeps its edge), an unscoped env ignore, a
  topic ignore and the accounting.

## 0.12.4 — 2026-10-02

Hub: `unresolved` now means only "the hub could not decide". Rows the hub can explain move to two new buckets,
`ignored` and `dynamic`, and every row there carries a `reason`, so nothing disappears silently. On the ewallet
hub, 60 unresolved rows go down to 3 (60 ignored, 19 dynamic), and 276 edges become 311: 43 are added and 8
removed. The removed ones are two report-ms datasource "http" edges (now db edges), three targets corrected by
the manifest and profile rules, and three UI links (auth-ms placeholders `backoffice.com` / `merchant.portal.com`, report-ms
`pay.winmoney.com.vn`).

- **Deploy manifests.** `aliases.json` takes `"manifests": "<dir>"` (relative to the hub root). The hub reads
  helm `values.yaml` (`env: {NAME: {value}}`) and k8s `env: [{name, value}]` read-only. It skips
  `secrets*.yaml`, `*.enc.yaml` and secret-looking keys, and it keeps only hosts, schemas and topic names. An
  env value there decides the target: a service by image basename, applicationName or `<name>.<namespace>`, or
  `external:<app>` for an app that is deployed but not registered in the hub, or `external:<host>`. When every
  manifest target is external (vendors stubbed in dev/uat), the public host of the yml default stays an edge too. A manifest
  topic value overrides `${ENV:default}`. Another service's datasource URL becomes a `db` edge to the owner of
  its deployed schema, instead of an http edge.
- **Profiles and dead config.** A client key from a test or local profile never becomes an edge or matches an
  alias. It goes to `ignored`, as a copy of its main-profile key or as test-only. A URL key that no `src/main`
  code reads (a map-registry entry nobody looks up) goes to `ignored`, and so does a portal, login or deeplink key.
- **Kafka from source.** Handler classes now count as consumers when their `getSupportedTopics()` / `topic()`
  returns a `@ConfigurationProperties` getter or an `@Value` field. Publisher route tables and outbox
  `saveEvent(…, topic)` calls now count as producers, as does `saveEvent(id, "type", payload)` with a topic
  prefix. These sources are read straight from the repo, because planes are frozen. Send sites in DLT/replay
  code, outbox publishers and wrappers that take the topic as a parameter go to `dynamic`. An empty topic
  property that is set nowhere goes to `ignored`, and so does a topic prefix no other service consumes.
- **UI links by use.** A URL key whose every `src/main` use is UI model data (`put`/`Map.of` with a literal key, a
  Mail/Notification/Template argument, via an `@Value` field or a `@ConfigurationProperties` getter chain) and
  none an HTTP client (`baseUrl`/`uri`/WebClient/RestTemplate/RestClient/HttpClient/Feign) goes to `ignored` as
  "UI link", before manifests and hosts are consulted. On ewallet this removes auth-ms `APP_BACKOFFICE_URL` /
  `APP_MERCHANT_PORTAL_URL` (4 manifest edges + the 2 placeholder hosts) and report-ms `TGTT_SERVICE_CHANNEL_URL`.
  A portal-named key with an HTTP-client use is never a UI link.
- **Nothing dropped silently.** A prefix the publisher bypasses (its topics routed explicitly, e.g. aml-service
  `aml.`) keeps a `dynamic` row naming the routed topics; a prefix-composed `saveEvent` topic cites the prefix
  line on its edge. A topic a service produces and consumes itself, a static topic no registered consumer names,
  and a client address naming its own service go to `ignored`. `links` keeps its totals line when clipped. On
  ewallet every input row is accounted for.
- `aliases.env` values may be `external:<host>`. Any user edit, including `manifests`, makes `aliases.json`
  user-owned. `links` and HUB.md show the three buckets, and `hub-sync` prints them as
  `N unresolved, N ignored, N dynamic`.

## 0.12.3 — 2026-10-01

Prompt audit of the v0.12.2 prompt surface (111 findings), and a hub brief fix.

- **Stale v0.11 machinery removed from prompts.** Rule templates, agents and skills no longer cite the Phase
  Loop, the "Phase 5 verify gate", `claudehut-config.json`, `reviewer-reactive`, the `plan-spec-coverage` script,
  `.claudehut/memory/`, a threat-model or arch-unit-check skill, or auditors that query DB/MCP live. Wrong names
  are fixed: `@MockitoSpyBean`, JSpecify `@NonNull`, the Boot 3 `management.prometheus.metrics.export.enabled` key.
- **Contradictions resolved.** The implementer's remedy for code written before its test matches the implement
  skill (delete and restart). The learner keeps the lines the harvest already wrote. Minimalism numbers the
  reuse ladder like Discover. Actuator exposure is `health,info` everywhere, and prometheus is allowed only behind
  the ADMIN chain or a scraper-only network policy. `REQUIRES_NEW` stays out of loops, and field self-injection is
  gone. Bean-validation failures map to 400. The db reviewer checks Flyway names against `flyway-naming.md`.
- **Plainer wording.** Thinking-time caps, all-caps laws and history narratives are rewritten as plain
  statements with their reasons. The dead `Reused & enhanced from committed rules/` tail is gone from rule headers.
- **Hub brief under long paths.** `brief --json` at the hub now counts its head lines (absolute hub and CLI paths)
  against the budget, so the sections still equal the markdown lines when the checkout path is long.

## 0.12.2 — 2026-10-01

Summer library (java-common-ms) support in the index, the hub and `claudehut-migrate`.

- **Per-module lib edges.** The hub draws one `lib` edge per (service, library module) instead of one
  `summer lib via io.f8a.summer:*` edge per service. Each edge carries the module, the version and where it came
  from (`explicit`, `property`, `catalog`, or `bom` = the service's platform/BOM version), and `scope: test` for
  test-only deps. The dependency parser reads string, map-style (`group:/name:/version:`) and version-catalog
  (`libs.x.y`, `version.ref`) declarations, resolves `${var}` from `gradle.properties` / `ext`, and ignores comments.
  A repo that publishes ≥2 Gradle modules (maven-publish / java-platform, no Boot app plugin) is detected as a
  library and owns its group; module names follow its `settings.gradle` (the `'summer'.concat('-'…)` style too).
- **`svc <library>`** prints modules × consumers × versions with `SKEW` markers, unused and unpublished modules;
  `svc <consumer>` lists `Libs from <library>: <module> <version>…`; `links --module <name>` lists every consumer of
  one module (the impact of a change). HUB.md folds lib edges into a "Shared libraries" section with BOM skew.
- **Library surface in the index.** In a library repo the index adds `module` rows (module → artifact),
  `autoconfig` rows from `META-INF/spring/*AutoConfiguration.imports` and `spring.factories`, `properties` rows
  (`@ConfigurationProperties` prefix + kebab-case keys, nested types expanded), public `annotation` / `spi` types and
  `@Bean` factories, each tagged with its module. A service's own `@interface`s stay unindexed.
- **Summer KB stays current.** `java-common-ms/.claude/summer-kb/` gets its own `.summer-kb-meta.json` stamped with
  the library's git HEAD. `install_summer_kb.py --if-stale` installs a missing KB, refreshes one whose summerCommit or
  module set moved, and otherwise writes nothing; it reads the build with the hub's parser, so a KB's modules are the
  service's `lib` edges. `claudehut-migrate` runs it for every service (java-common-ms first) and reports
  `summer-kb: refresh N, install M, up-to-date K`; SessionStart starts a detached refresh on a stale stamp. A
  hand-edited `.claude/rules/summer-kb.md` is never rewritten.

## 0.12.1 — 2026-10-01

Fixes found while migrating the real ewallet workspace.

- **One hub entry per repo.** `claudehut-migrate` hub-scans a repo without a plane under its dir name
  (`ekyc-int-ms`). A later `claudehut-init --mode microservice --hub` registered it again under its build name
  (`kyc-ms`), so `services.json` held two entries with one path and that repo's edges were doubled (158 instead
  of 148). Init now drops the other entry with the same path. `hub-sync` and `hub-scan` collapse entries that
  resolve to one repo: they keep the key the repo's `topology.json` names and remove `links/*.json` files of
  unregistered services. Running `hub-sync` once repairs a hub that 0.12.0 left doubled.
- `topic_owner` and `db_owner` in `aliases.json` accept a repo dir name for its service key, like `env` and
  `lib_owner` already did.
- **`claudehut-migrate --dry-run` on a migrated workspace reports 0 changes.** The simulated copy wrote its temp
  path into generated files (the MEMORY.md plane line, the git-hook shim path), so about 50 identical files were
  listed as modified. The plan now compares content with that prefix removed.

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
