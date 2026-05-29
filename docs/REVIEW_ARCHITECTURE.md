# ClaudeHut — Architecture & Implementation Review

> **Reviewer perspective:** external, adversarial ("khắc khe nhất"), grounded in current Claude Code documentation, Anthropic's agent‑engineering guidance, the relevant `anthropics/claude-code` issue tracker, and the competitive plugin landscape.
> **Scope reviewed:** the implementation‑accurate reference doc dated 2026‑05‑29 (plugin v0.1.0) + the public repo `taipt1504/claudehut`.
> **Date:** 2026‑05‑29.
> **Conventions:** every claim about Claude Code behavior is tied to a doc or issue number. Severity tags: **P0** = breaks as designed / task can't complete, **P1** = silently wrong, **P2** = robustness / cost / DX. Findings the source doc already self‑flagged are marked _(self‑flagged — validated)_; the rest are new.

---

## 0. TL;DR (tiếng Việt)

ClaudeHut là một plugin **rất tham vọng và rất kỷ luật** — artifact‑derived state machine, harness‑level enforcement, stub‑commit trước parallel build, Bash 3.2 portability, 375 test assertions, và tài liệu cực kỳ trung thực về chính những điểm yếu của nó. Triết lý cốt lõi (đẩy enforcement xuống hook/harness thay vì tin vào model) **đúng** và trùng với đồng thuận của cộng đồng Claude Code (issue #49106).

Nhưng có ba nhóm vấn đề lớn:

1. **Một số chỗ có thể không chạy đúng như thiết kế trên runtime hiện tại.** Quan trọng nhất: Phase 5 dựa vào việc _verifier (một subagent) lại spawn 2–6 reviewer subagent_ — nested Task/Agent dispatch **không được hỗ trợ** (issue #4182, #61993). Cộng với findings‑path bị tách đôi (Q2) → task có thể không bao giờ thoát `loop`. Và decision rule trong script (`high < 3`) mâu thuẫn spec (`high == 0`) → 2 finding High vẫn "pass" âm thầm.

2. **"Reinforcement learning" hiện tại không phải là học.** Nó là _append‑only note + dump `head -200` vào mọi prompt_. Anthropic khuyến nghị ngược lại: just‑in‑time retrieval, chỉ nạp cái liên quan. Memory MCP server đã khai báo nhưng **chưa được dùng** để retrieve.

3. **Kiến trúc multi‑agent nặng áp dụng cho coding — đúng domain mà Anthropic nói multi‑agent _kém_ hiệu quả** (coding là interdependent), với chi phí ~15x token và **không có cost cap**. Plus: monolith quá lớn (17 agent + 29 skill + 45 rule) trong khi xu hướng tốt là modular.

Khuyến nghị xương sống để tiến tới "Harness agent" thật sự: **(a) adaptive depth/routing** (đừng bắt fix 1 dòng cũng đi đủ 6 phase), **(b) memory retrieval theo relevance + outcome signal** (đây mới là "thông minh hơn theo thời gian"), **(c) eval harness để đo**, **(d) dùng primitive native + cân nhắc Claude Agent SDK cho orchestrator**, **(e) modular hóa**. Chi tiết bên dưới (tiếng Anh, để tiện share cho reviewer ngoài).

---

## 1. Scorecard

| Dimension                                | Score | One‑line verdict                                                                                                                                                                    |
| ---------------------------------------- | ----- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Design vision / ambition**             | 9/10  | Genuinely thoughtful; the artifact‑derived state machine and harness‑enforcement thesis are first‑rate.                                                                             |
| **Architecture soundness**               | 5/10  | The thesis is right, but the multi‑agent‑for‑coding fit is wrong per Anthropic's own guidance, and one headline mechanism (reviewer fan‑out) likely doesn't run on current runtime. |
| **Platform correctness**                 | 4/10  | Several claims rest on stale or contradicted platform behavior (CLAUDE.md→subagent, nested dispatch, skill preload under `--print`).                                                |
| **Implementation quality / portability** | 8/10  | Bash 3.2 discipline, EXIT‑trap cleanup, path canonicalization, `-B` worktree idempotence — this is careful systems code.                                                            |
| **Testing**                              | 6/10  | Impressive _breadth_ (375 assertions) but ~90% is static/structural lint; behavioral coverage is 3 opt‑in prompts. No output‑quality eval.                                          |
| **Memory / learning**                    | 3/10  | "Reinforcement learning" is a misnomer: static note‑injection, no retrieval, no outcome signal, declared memory MCP unused.                                                         |
| **Cost‑efficiency**                      | 3/10  | Research‑grade token spend on a domain where the parallelism dividend is small; no token caps or telemetry.                                                                         |
| **Maintainability / org**                | 5/10  | Monolith with hand‑synced duplication (guardrails ×3); spec/impl drift already visible in the doc itself.                                                                           |
| **Security posture**                     | 5/10  | Secret‑scan and plugin packaging are correct; the destructive‑command "allowlist" is security theater (advertised, never read, regex‑bypassable).                                   |
| **Documentation honesty**                | 10/10 | Rare and admirable: it flags its own discrepancies instead of hiding them. This review exists _because_ the doc is honest enough to review.                                         |

**Headline verdict:** ClaudeHut is a _strong workflow engine with an aspirational agent label_. The engineering craft is real. The biggest risks are (1) two/three correctness bugs that can stall or silently weaken the pipeline, (2) a learning subsystem that doesn't learn, and (3) an architecture priced for research applied to coding. All three are fixable without abandoning the core design.

---

## 2. What ClaudeHut gets genuinely right

These are not throwaway compliments — each is a defensible design decision validated against external sources.

**2.1 Artifact‑derived, stateless phase machine.** Deriving phase from disk artifacts + branch name (no mutable `state.json`) is the correct call. It eliminates the write‑then‑read race, survives crashes/interrupted hooks, and resets naturally on branch checkout. This is exactly the "external state, re‑derive on demand" pattern Anthropic's context‑engineering post recommends (state that outlives the context window). The trade‑off (phase becomes a pure function of disk conventions) is acceptable and the doc names it.

**2.2 Harness‑level enforcement over model goodwill — and it's aligned with community consensus.** ClaudeHut's central thesis ("don't trust the model to carry rules across subagents; enforce with hooks + `--append-system-prompt`") is precisely what Claude Code issue **#49106** documents: subagent rule‑adherence degrades to ~5% coverage by the 4th task in multi‑subagent sessions because instruction inheritance is left to the model under context pressure, and the recommended fix is _harness‑level injection_. ClaudeHut independently arrived at the right answer. The fixed per‑task `--append-system-prompt` guardrail fragment is the correct mechanism.

**2.3 The stub‑commit step is a genuinely clever mitigation.** Generating compiling skeletons once, committing them, and branching all parallel workers from that commit removes the three classic parallel‑build failure modes (contract drift, hidden dependency, semantic merge conflict). This is the kind of insight that only comes from actually running parallel builds. (Note in §4 that it's a _mitigation for a domain mismatch_ — but as a mitigation it's well‑designed.)

**2.4 Bash 3.2 / POSIX‑awk portability is taken seriously.** Targeting macOS system bash, banning `mapfile`/`declare -A`/`${var,,}`/`wait -n`/gawk 3‑arg `match()`, the `${arr[@]+"${arr[@]}"}` empty‑array guard under `set -u`, and the EXIT‑trap worktree cleanup are all marks of someone who has been burned and learned. The path‑canonicalization fix (`pwd -P` on both sides for the `/tmp`→`/private/tmp` symlink) is a real bug found by a real e2e — exactly the class of issue that only surfaces with live `claude` workers.

**2.5 Plugin packaging is the _correct_ choice for skill loading.** Issue **#16616** shows user‑level skills (`~/.claude/skills/`) load their full body into context (10k+ tokens) while _plugin_ skills correctly load frontmatter‑only at startup. By shipping as a plugin, ClaudeHut gets the cheap, correct loading path. Good instinct.

**2.6 Secret‑scan before persisting learnings.** Running 12 hard‑reject regexes over every learning candidate, logging only the pattern class (never the matched text), append‑only with `replaces:`/`tombstone` instead of in‑place edits — this is the right hygiene for a file committed to a shared repo. Aligned with the "least‑privilege, no secrets in prompts/memory" guidance the ecosystem stresses.

**2.7 Radical documentation honesty.** The doc flags `loop_max_retries` as a no‑op, the findings‑path split, the decision‑rule split, the `claudehut-state stack` grep bug, and the `has_learnings` compact‑JSON assumption — _before an external reviewer could_. This is the opposite of most plugin READMEs. It dramatically lowers review risk and is itself a quality signal.

---

## 3. Architectural positioning: workflow vs. agent (the core tension)

The user's stated goal is a **"Harness agent"**: agents that _autonomously_ receive a request, decide which skills/rules to apply, execute, and _get smarter over time_. ClaudeHut, as built, is something different — and the gap matters.

Using Anthropic's own taxonomy from _Building Effective Agents_:

> **Workflows** = LLMs/tools orchestrated through _predefined code paths_. **Agents** = LLMs that _dynamically direct their own processes_.

ClaudeHut is, by its own description, a **non‑skippable, deterministic, predefined 6‑phase pipeline**. That is squarely a **workflow**, not an agent. Concretely it composes four of Anthropic's five canonical patterns:

| ClaudeHut mechanism                                 | Anthropic pattern                         |
| --------------------------------------------------- | ----------------------------------------- |
| Brainstorm → Spec → Plan → Build → Loop → Learn     | **Prompt chaining**                       |
| Build: orchestrator → N parallel `--print` builders | **Orchestrator‑workers**                  |
| Loop: verify → review → refactor → re‑verify        | **Evaluator‑optimizer**                   |
| Reviewer fleet (2–6 reviewers on the same diff)     | **Parallelization / voting (sectioning)** |

This composition is legitimate and well‑known. But two things follow:

**3.1 The rigidity is in direct tension with the "autonomous agent" aspiration.** A fixed pipeline is the _opposite_ of "agents dynamically directing their own processes." That's not necessarily wrong — for a **fintech/payments** codebase, predictability and gates are a feature, and Anthropic explicitly endorses workflows when steps are predictable. But the doc should stop calling this an "agentic" system that "learns" and instead position it honestly as a _governed workflow with a learning side‑channel_. The path to the user's actual goal is **adaptive depth** (§9.A), not more agents.

**3.2 Anthropic's "start simple, add complexity only when needed" is violated at v0.1.0.** The canonical guidance is explicit: find the simplest solution, increase complexity only when simpler approaches demonstrably fall short. ClaudeHut launches at _maximum_ complexity — 17 agents, 29 skills, 45 rules, 8 hooks, 5 MCP servers, two execution tiers — with **no evidence presented that a simpler baseline was insufficient**. There is no measured comparison against, say, "plain Claude Code + a good `CLAUDE.md` + the bundled `/code-review` and `/loop` skills." Without that baseline, the entire apparatus is unfalsifiable: you cannot show it helps. (This is why §9.C — an eval harness — is not optional.)

**3.3 Multi‑agent fan‑out is being applied to the one domain Anthropic flags as a poor fit.** From _How we built our multi‑agent research system_: multi‑agent systems use **~15× the tokens of a chat** (vs ~4× for a single agent), excel at **breadth‑first, independent** subtasks, and are **"less effective for tightly interdependent tasks such as coding."** Coding is interdependent _by nature_ — which is exactly why ClaudeHut must bolt on the stub‑commit + per‑group compile gate + surgical‑scope hooks to make parallel builders safe. That machinery is impressive, but it exists to paper over a structural mismatch: you are paying research‑grade token cost for a domain where the parallelism dividend is muted. (Anthropic's own data: token volume explains ~80% of performance variance; _model choice ~5%_ — see §8 on cost.)

**3.4 It reinvents native Claude Code primitives that now exist.** Several hand‑rolled mechanisms duplicate platform features shipped since the design was conceived:

| ClaudeHut hand‑rolls…                                                                              | Native primitive (Claude Code docs)                                                      |
| -------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| `dispatch-prompt.sh` + `Task(subagent_type=…)` to fork a phase agent                               | Skill `context: fork` + `agent:` frontmatter                                             |
| "auto: editing `**/*Controller.java`" trigger prose + the `using-claudehut` dispatch‑mapping table | Skill `paths:` frontmatter (glob‑scoped auto‑activation)                                 |
| The whole Loop phase                                                                               | Bundled `/code-review` + `/loop` skills                                                  |
| `discover` / build‑recipe capture                                                                  | Bundled `/run-skill-generator`, `/run`, `/verify`                                        |
| `pre-compact.sh` re‑surfacing artifacts                                                            | Native skill re‑attachment after compaction (25k‑token budget) + the `PostCompact` event |

Reinventing is defensible _only if_ the native primitive is unreliable (and §5.4 shows `context: fork` has indeed been flaky — #49559, #17283). But the doc never makes that argument explicitly, and `paths:` activation is stable and should be adopted now.

---

## 4. P0 — Issues that can break the pipeline as designed

### 4.1 The reviewer fleet relies on nested subagent dispatch, which is unsupported _(new — highest impact)_

Phase 5's headline mechanism: the orchestrator dispatches `claudehut-verifier` via `Task`, and **the verifier itself dispatches 2–6 `claudehut-reviewer-*` subagents via `Task` in one message.** That is a two‑level `Task → Task` nesting.

Current Claude Code does not support this. Issue **#61993** (and the older **#4182**) document that a subagent spawned via the Agent/Task tool finds `Task`/`Agent` **absent from its tool surface** — only top‑level sessions can spawn subagents; nested contexts have the primitive filtered out. Putting `Task` in the verifier's `tools:` frontmatter does **not** help, because the runtime strips it in nested contexts regardless of frontmatter.

**Consequences if true on the target version:**

- Best case: the verifier silently runs all reviews _inline_ in its own single context — losing both the per‑reviewer isolation and the parallelism that justify the fleet, and inviting exactly the rule‑degradation #49106 describes (one context trying to be six specialists).
- Worse case: the dispatch errors out and Phase 5 never produces `findings.json` → phase never advances.

This is the single most important finding because the reviewer fleet is a marquee feature and **the doc presents the nesting as a deliberate, sanctioned design** ("the single sanctioned fan‑out point") without acknowledging the platform constraint.

**Fixes (pick one):**

1. **Flatten** — the _orchestrator_ (top level) dispatches the reviewers directly (it _can_ spawn subagents and _can_ batch them in one message). The verifier degrades to a pure pre‑step (run verify gates) + the aggregator script runs afterward. This is the smallest change and is the most platform‑honest.
2. **Path‑B reviewers** — run reviewers as headless `claude --print &` processes exactly like builders (OS‑level parallelism, no Task nesting). Reuses machinery you already have.
3. **Experimental agent‑teams** (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`) — but this is gated/undocumented and itself has the skill‑preload gap (#29441); not recommended as the primary path.

Validate empirically: run a real session, then `grep -o '"subagent_type":"[^"]*"' ~/.claude/projects/<cwd>/<session>.jsonl` and confirm reviewer dispatches actually appear _under_ the verifier. #49559's reproduction shows zero dispatches when the harness silently inlines instead.

### 4.2 Findings‑path split → task can never leave `loop` _(self‑flagged Q2 — validated, re‑ranked to P0)_

`run-verify-parallel.sh` (and `reviewer-dispatch.md`) reference `.claudehut/state/tasks/<id>/findings.json`, while `state.sh::claudehut_findings_doc()` reads `.claudehut/findings/<id>-findings.json`. The doc names `.claudehut/findings/<id>-findings.json` as authoritative — but if the verify script _writes_ to the `state/tasks/` path, `claudehut_findings_decision()` returns `""` forever → `claudehut_phase()` stays at `loop` → infinite loop / stuck task.

The doc treats this as "an inconsistency." It is a **task‑can't‑complete** bug. There must be **exactly one** canonical path, and a test (L11) that _writes via the real verify code path and reads via `state.sh`_ — the current L11 simulates the write with `subagent-stop.sh` and so would not catch a write/read path divergence in the production script.

### 4.3 Decision‑rule split → silently ships High findings _(self‑flagged Q1 — validated, P0/P1 boundary)_

`aggregate-findings.sh` writes `pass` when `critical == 0 AND high < 3`. The verifier agent's gate G5 and SKILL prose say `0 critical AND 0 high → pass`. So a diff with **two High findings graduates to Learn**, marked "pass," with no user awareness — and because phase advancement reads that JSON, the build proceeds to `done`.

For a **fintech/payments** plugin whose reviewers flag security (OWASP, SpEL injection, Jackson RCE) and DB/migration safety, silently shipping 2 High findings is a real safety regression, not a cosmetic mismatch. Worse, **the L11 test encodes `high < 3`**, so the test suite currently _enshrines the bug_ and would reject the correct behavior.

**Fix:** decide the contract deliberately. If `high == 0` is intended (likely, for fintech), fix the script _and_ the test, and surface the exact failing finding. If `high < 3` is intended (a "minor‑warnings‑allowed" policy), then fix the agent prose and document the rationale loudly — but I'd argue against it for this domain.

---

## 5. P1 — Silent incorrectness / stale platform assumptions

### 5.1 Path B's central justification is partly self‑defeating _(new)_

The doc justifies the entire Path‑B (`claude --print`) architecture by citing bug **#25834** (plugin subagent `skills:` preload silently fails) as a reason to avoid Task‑tool subagents. But:

- **#25834 is real** (confirmed, macOS): plugin‑deployed agents referencing plugin skills get _no_ skill injection, silently. So the concern is valid.
- **However, #29441 shows the same class of bug affects CLI‑process spawning** — "team orchestration spawns teammates as independent CLI processes … that process‑level startup path does not consume the `skills:` field." A `claude --print` worker is exactly such an independent CLI process. And ClaudeHut's own build‑references doc admits the model reported preloaded skills as **"none"** under `--print`.
- Meanwhile **#27736** reports that for in‑process Task subagents the skills _are_ injected (only the Task tool's _description_ omits them).

**Net:** Path B was chosen partly to dodge a preload bug, but **Path B appears to have the same preload gap**, while the alternative (Task subagents) may actually preload correctly in the in‑process path. The architecture's load‑bearing rationale is shaky in both directions.

**Implication:** TDD discipline in builders rides _entirely_ on the `--append-system-prompt` guardrail fragment + the persona body loaded via `--agent`. Anything in the `tdd-cycle`/`build` skills that is **not duplicated** in those two places is silently absent in every worker. The mitigation (lift TDD essentials into persona/guardrails) is partly done — finish it, and add a startup self‑check where the worker echoes which skills it actually has so CI can assert it. Then re‑evaluate whether Path B still earns its complexity vs. flattened Task dispatch.

### 5.2 Subagents no longer receive CLAUDE.md — the doc's mental model is stale _(new)_

§10/§11 state that a subagent automatically receives "the CLAUDE.md hierarchy." Since **v2.1.84**, that is no longer true by default: issue **#40459** documents `tengu_slim_subagent_claudemd` (default **true**) / `omitClaudeMd:true`, which strips CLAUDE.md from subagents (Explore, Plan, built‑in, and custom). The skills doc corroborates: built‑in Explore/Plan agents _skip_ CLAUDE.md to keep context small.

**Why it matters here:** ClaudeHut's memory delivery to subagents depends partly on the `@import` of `conventions.md` / `stack-signals.md` / `learnings-recent.md` _in CLAUDE.md_. If subagents don't get CLAUDE.md, that channel is dead for them. The system is _saved_ by the `dispatch-prompt.sh` redundancy (it re‑injects stack/conventions/learnings directly) — which is excellent defensive design and should be celebrated — **but the doc must stop claiming CLAUDE.md reaches subagents**, and `learnings-recent.md` must never be relied on reaching a subagent via `@import` alone.

### 5.3 Stop‑enforcement can create an unbreakable stop loop _(new)_

When `phase.stop_enforcement_enabled: true`, `stop.sh` emits `decision:"block"` at `phase=learn` to force the learner to run. Issue **#57249** documents the failure mode directly: a Stop hook whose gate can _never_ succeed drives the session into the **3‑stop‑hook loop**. If the learner can't complete (model/billing tier mismatch as in #57249, a worker crash, a malformed `learnings.jsonl`, or the `has_learnings` grep in §6.4 failing), the block fires repeatedly until Claude Code's stop‑hook cap, wasting turns and confusing the user.

**Fix:** add a bounded escape — e.g., after N stop‑blocks for the same task, downgrade to a non‑blocking `systemMessage` and surface "learner could not complete; run `/claudehut:learn` manually or `claudehut-finish --skip-learn`." Never let an unsatisfiable gate hard‑block indefinitely.

### 5.4 The `findings.json` concurrent write is a lost‑update race _(self‑flagged Q6 — validated)_

`subagent-stop.sh` and `aggregate-findings.sh` both do **read‑modify‑write via `jq` + tmp‑file + `mv`** on the _same_ `findings.json`. If two reviewers' `SubagentStop` events fire concurrently (likely, since they're dispatched together), the second `mv` clobbers the first's write — a classic lost update. `mv` is atomic at the filesystem level but the _read→jq→write_ sequence is not atomic across processes.

**Fix:** make each reviewer write its own shard (`findings/<id>/reviewer-<name>.json`) and have the aggregator do a single‑reader merge at the end; or take a coarse lock (`mkdir`‑based mutex, Bash‑3.2‑safe) around the read‑modify‑write. (This race also intersects with §4.1: if you flatten the reviewer fleet, concurrency still exists, so the shard approach is the durable fix regardless.)

### 5.5 A PreToolUse _hook_ cannot dispatch a Task subagent _(new — architectural‑accuracy)_

§4/§6/§10 repeatedly say the `PreToolUse` hook "invokes `claudehut-migration-validator` as an Agent‑tool subagent" on every `**/db/migration/V*.sql` write. A `PreToolUse` hook is a **shell script**; it has no access to the model's `Task`/`Agent` tool. It can only (a) run a shell command or (b) emit `permissionDecision`. So one of two things is actually happening, and both have consequences the doc doesn't address:

- If the hook shells out to `claude --print --agent claudehut-migration-validator`, then **every single migration write spawns a full headless Claude session** — real latency (seconds) and token cost on each write, plus all the Path‑B caveats (§5.1) — inside a _blocking_ PreToolUse gate (10–20 s timeout). That's fragile.
- If the "validation" is really the **regex** in the rule file, then it should be a pure script gate (like the destructive‑bash block), and the "invokes a subagent" language is inaccurate.

**Action:** pick the model explicitly. For statically‑matchable DDL hazards (the doc's own examples: `CREATE INDEX` without `CONCURRENTLY`, `ADD COLUMN NOT NULL` without `DEFAULT`), a deterministic regex gate is faster, cheaper, and has zero false‑negative risk — no LM needed. Reserve LM reasoning for genuinely contextual checks and run it at Loop time (reviewer tier), not in a per‑write blocking hook.

---

## 6. P2 — Robustness, DX, and the issues the doc already knows about

### 6.1 `loop_max_retries` userConfig is decorative _(self‑flagged #7 — validated)_

The threshold `3` is hardcoded in the verifier, dispatch scripts, and `claudehut_loop_retries`. The `plugin.json` field (range 1–10) is never read. For a plugin aimed at teams with differing risk tolerance, this matters. **Fix:** read `claudehut-state config phase.loop_max_retries` at runtime; default to 3; fall back gracefully. Add a test that sets it to 5 and asserts a 4th retry occurs.

### 6.2 `destructive_command_allowlist` is security theater _(new + self‑flagged #8)_

Two problems compound. First, the bash‑mode block advertises an allowlist key it **never reads** (#8). Second — more seriously — the deny regex (`rm -rf /`, `git push --force`, `DROP DATABASE`, `kubectl delete`, `--no-verify`) is **trivially bypassable**: `rm -r -f /`, `rm -fr ~/`, `rm --recursive --force "$HOME"`, `git push -f`, base64/`eval` indirection, or any path that isn't literally `/` all slip through, and any _new_ destructive verb isn't covered. Presenting this as a safety control invites false confidence — especially dangerous in a fintech context.

**Fix:** (a) remove the misleading allowlist text _or_ actually implement it; (b) reframe the block honestly as "best‑effort speed‑bump, not a sandbox"; (c) consider gating force‑push on branch name (allow on non‑protected feature branches, which is the legitimate rebase case the doc worries about) rather than a blanket block; (d) for real isolation, rely on Claude Code's own permission system and OS sandboxing, not a regex.

### 6.3 `claudehut-state stack` can't match `stack-signals.md` _(self‑flagged #9 — validated)_

Prepending `.` to the field (`web` → `.web`) makes the grep `^- .web:`, which won't match `- web:` as intended; the help text also says `stack-signals.json` (actual file is `.md`). Any code path branching on `claudehut-state stack <field>` silently gets empty. **Fix:** drop the `.` prefix, correct the help text, and add an L2 unit test that asserts `claudehut-state stack web` returns the real value from a fixture.

### 6.4 `claudehut_has_learnings` is brittle to JSON formatting _(self‑flagged — validated; intersects §5.3)_

`grep -qF '"task_id":"<id>"'` only matches compact JSONL with no space after the colon. A pretty‑printed entry (`"task_id": "…"`) never matches → phase stuck at `learn` forever → and with stop‑enforcement on, the §5.3 loop. **Fix:** parse with `jq` (`jq -e --arg id "$id" 'select(.task_id==$id)'`) or canonicalize on write _and_ validate on read. Enforce a single learner write contract.

### 6.5 `git branch = task identity` is elegant but brittle _(self‑flagged trade‑off — expanded)_

The slug transform (`tr '/' '-' | tr -c '[:alnum:]-' '-'`) and the protected‑branch → `none` rule create four sharp edges: (1) **one active task per branch** — no concurrent features on a branch, no multiple tasks per PR; (2) **branch rename silently orphans** all artifacts (`specs/<old>-design.md` etc.); (3) **slug collisions** — `feat/foo.bar` and `feat/foo-bar` both map to `feat-foo-bar`; (4) **protected‑branch lockout** — legitimate hotfixes directly on a release branch are impossible. The `CLAUDEHUT_TASK_ID` escape hatch helps workers but not humans. **Fix:** at minimum, write a small `task-id → branch` pointer file at task creation so a rename can be detected/repaired, and warn on slug collision at `init`/branch‑create time.

### 6.6 Skill‑listing budget overflow can silently disable auto‑triggering _(new)_

The skills doc is explicit: skill **descriptions** are loaded into context for auto‑trigger matching, capped at **1,536 chars** each, sharing a budget of **~1% of the model's context window** (`skillListingBudgetFraction`), and **when it overflows, the least‑used skills' descriptions are dropped first**. ClaudeHut ships ~29 skills with deliberately verbose, trigger‑rich descriptions (Vietnamese + em‑dashes inflate byte counts). On a busy session with other plugins also contributing skills, the rarely‑auto‑invoked domain skills (e.g., `nats`, `rabbitmq`) can lose their descriptions → they stop auto‑triggering, **silently undermining the "1% rule."** The 1% rule itself can't fire on a skill the model can no longer see.

**Fixes:** (a) adopt native `paths:` for activation (path‑glob matching doesn't depend on the description budget); (b) trim descriptions, key use case first; (c) set rarely‑auto‑invoked skills to `"name-only"` via `skillOverrides`; (d) run `/doctor` to see if the budget is overflowing. This also reduces the steady‑state token cost.

### 6.7 The "1% rule" is a blunt instrument that fights the platform _(new)_

Mandating skill invocation on "even a 1% chance it matches" maximizes token spend and latency, and runs against Anthropic's core context‑engineering guidance ("smallest set of high‑signal tokens," "keep 3–5 most‑used tools always available, retrieve the rest just‑in‑time"). Over‑invocation also accelerates the post‑compaction eviction problem (the 25k‑token re‑attach budget fills with low‑value skills, dropping the ones that matter). Combined with §6.6, the 1% rule can paradoxically make the system _less_ likely to use the right skill. **Fix:** replace the hard 1% mandate with `paths:`‑driven activation + a relevance threshold, and trust strong descriptions (the platform's intended mechanism).

### 6.8 `integrations.json` single‑writer race across split windows _(self‑flagged — validated)_

`session-start.sh` overwrites `integrations.json` every SessionStart with no merge; two simultaneous sessions for the same repo → last write wins. Low impact, but a `mkdir` mutex or per‑session filename would close it.

---

## 7. The "learning" subsystem — the gap between the label and the implementation

This is the section the user cares about most ("luôn có khả năng học tăng cường để luôn thông minh hơn theo thời gian / Harness agent"), so it deserves a frank treatment.

**7.1 What's implemented is not reinforcement learning — it's static note injection.** The Learn phase extracts JSONL "learnings," secret‑scans them, appends them, regenerates a markdown view, and a promotion counter copies frequently‑seen signatures to a global file. Retrieval is **`head -200 learnings-recent.md` dumped wholesale into every subagent prompt**. There is:

- **no reward signal** (nothing measures whether a learning _helped_),
- **no policy update** (agent behavior doesn't change in a learned way — the same static text is injected regardless of task),
- **no relevance retrieval** (a Kafka task gets the same 200 lines as a JPA task),
- **no use of the declared `memory` MCP knowledge‑graph server** — it's effectively _vestigial_.

Calling this "reinforcement learning" oversells it. As implemented it is closer to a **team wiki that's force‑fed into every prompt**.

**7.2 It actively violates Anthropic's memory guidance and risks context rot.** _Effective context engineering for AI agents_ is explicit: durable memory should hold **only information that continues to constrain future reasoning**; storing/injecting too much creates **persistent context pollution**; the recommended pattern is **just‑in‑time retrieval**, not stuffing everything into the prompt; and context rot degrades retrieval accuracy by up to ~30% as token count grows. ClaudeHut's "inject the last 200 lines of learnings into every worker" does the opposite, and it gets _worse_ as the project accumulates learnings — the system's "memory" makes it dumber over time, not smarter, past a threshold.

**7.3 Promotion is frequency‑based, not quality‑based.** "Appears in ≥3 projects" promotes a _common_ learning, not necessarily a _good_ one. A widely‑repeated anti‑pattern or a stale convention promotes just as easily as a genuine insight.

### What "gets smarter over time" should actually mean (concrete redesign)

This is achievable without model fine‑tuning. Think of it as **retrieval reinforcement**, and say so honestly:

1. **Just‑in‑time, relevance‑ranked retrieval (replaces `head -200`).** At dispatch, query for the top‑k learnings relevant to _this task_ (by touched file paths, package, detected stack axes, and the task title). Two viable backends, and you already declared one:
   - Wire the **`memory` MCP knowledge‑graph server** you ship (`mcp-graph.json`) — link learnings to entities (classes, packages, patterns) and traverse from the task's files. It's currently declared and unused; using it would be the cheapest win.
   - Or add a lightweight **embedding/TF‑IDF index** over learnings (others in the ecosystem do exactly this — see claude‑mem, and the TF‑IDF KB plugins). Inject only the top 3–7 hits. This is the operationalization of RAG at agent time that Anthropic's context post points to.

2. **Outcome signals → a usefulness prior (the "reinforcement").** Track, per learning: how often it was _retrieved_, and what happened _after_:
   - retrieved AND the Loop converged in fewer retries → ↑ usefulness;
   - retrieved AND the same anti‑pattern got flagged anyway → ↓ usefulness;
   - never retrieved in `decay_days` → deprecate (you already have decay; tie it to _retrieval_, not just age).
     Rank retrieval by this prior (a simple bandit‑style weight). _This_ is the feedback loop that makes the system measurably better at surfacing the right knowledge over time — and it's honest to call it that, not "RL."

3. **Quality‑gated promotion.** Promote on `(frequency ≥ N) AND (never tombstoned/contradicted) AND (tasks that used it passed first‑try at rate ≥ threshold)`.

4. **Meta‑learning into rules/skills (the real "compounding intelligence").** When a reviewer flags the _same_ anti‑pattern across K tasks, don't just log a learning — **propose** a new `rules/` entry or a strengthened skill section, surfaced to the user for approval (never auto‑edit rules; that's an unbounded self‑modification risk). Approved proposals harden the _enforcement_ layer, which is where ClaudeHut's strength actually is. This closes the loop from "we keep seeing X" to "X is now structurally prevented."

5. **Honest framing in the docs.** Rename the section "Memory & Retrieval Reinforcement," not "Reinforcement Learning." It will read as _more_ credible to the external reviewers (Codex/Mythos), not less.

---

## 8. Cost & observability

**8.1 No token/cost cap, and the multiplier compounds.** Anthropic's multi‑agent post is blunt that the _published_ architecture has **no circuit breakers or per‑run caps**, and that the ~15× multiplier compounds another ~10× when something misbehaves (e.g., a subagent recursively spawning subagents — _exactly_ the §4.1 verifier→reviewer shape, and the §5.5 per‑write validator). ClaudeHut has the per‑worker watchdog (good — a wall‑clock circuit breaker) but **no token budget**. For a plan of 3 groups × 4 tasks, that's up to 12 full Sonnet sessions, each potentially to the 900 s timeout, plus the verifier + up to 6 reviewers + stub session + learner.

**Fix:** add a per‑task and per‑run token budget (kill/skip on breach) and a global run cap, configurable. This is table stakes for any production multi‑agent system per the same source.

**8.2 No cost telemetry.** You can't manage what you don't measure, and the ecosystem already has the pattern (the _Manifest_ plugin: per‑run token/cost/model observability). Emit per‑phase token + cost into `.claudehut/logs/` and a run summary. This also feeds §9.C (evals) and §7.2 (usefulness signals).

**8.3 Reconsider the model tiers — with data.** opus for brainstormer/planner is plausible but unvalidated. Anthropic's BrowseComp analysis attributes ~80% of performance variance to _token volume_ and only **~5% to model choice**. That suggests _enough tokens on Sonnet_ may match _opus with fewer tokens_ for planning — at materially lower cost. Don't guess; measure both on your eval set (§9.C) and keep `agents.builder_model` / `reviewer_models` as the knobs you already have.

---

## 9. Prioritized roadmap toward the "Harness agent" vision

Ordered by impact‑to‑effort. P0/P1 fixes first (they're prerequisites for trusting any measurement), then the strategic upgrades.

### Immediate (correctness — do before anything else)

- **[P0]** Resolve §4.1: flatten the reviewer fleet to orchestrator‑level dispatch (or Path‑B reviewers); verify dispatches actually appear in the session transcript.
- **[P0]** Resolve §4.2: one canonical `findings.json` path; test write‑and‑read through the _real_ code path.
- **[P0/P1]** Resolve §4.3: reconcile the `pass` decision rule; fix the test that currently enshrines `high < 3`.
- **[P1]** §5.4: shard reviewer writes (or lock) to kill the lost‑update race.
- **[P1]** §5.3 + §6.4: bounded stop‑block escape + `jq`‑based `has_learnings`.
- **[P1]** §5.2: correct the docs (CLAUDE.md does _not_ reach subagents); confirm `dispatch-prompt.sh` is the _sole_ memory channel for subagents.
- **[P2]** §6.1, §6.2, §6.3: wire `loop_max_retries`; de‑theater the destructive block; fix `claudehut-state stack`.

### A. Adaptive depth / routing — the single highest‑leverage design change

Replace "non‑skippable 6 phases for everything" with an **orchestrator triage step** that routes by task class (Anthropic's _Routing_ pattern):

| Intent class                              | Pipeline                                                |
| ----------------------------------------- | ------------------------------------------------------- |
| Trivial fix (≤ a few lines, no new types) | Build + Verify only (skip Brainstorm/Spec/Plan/Learn)   |
| Bugfix                                    | Reproduce (`systematic-debug`) → Build → Verify → Learn |
| Small feature                             | Spec → Plan → Build → Verify (light reviewer set)       |
| Large/cross‑service feature               | Full 6‑phase                                            |
| Migration                                 | Always full + mandatory DB review                       |

The artifact‑derived state machine still _gates_ the chosen path; you're choosing _which_ artifacts are required, not letting the model freelance. This resolves the rigidity‑vs‑autonomy tension, slashes cost for the common case (where 15× is unjustified), and matches "start simple, escalate complexity." It also moves ClaudeHut genuinely toward "agent" (the orchestrator now _decides_ depth) without sacrificing governance.

### B. Real memory/retrieval reinforcement (§7 redesign)

Wire the declared memory MCP (or a TF‑IDF/embedding index) for just‑in‑time top‑k retrieval; add the usefulness prior driven by Loop‑convergence/hit signals; quality‑gate promotion; add the rule/skill meta‑learning proposals. This is the concrete answer to "thông minh hơn theo thời gian."

### C. Eval harness — you cannot claim improvement without it

Build a small benchmark of representative Spring tasks (a CRUD endpoint, a Kafka consumer with DLT, a Flyway migration, a reactive handler, a refactor). For each plugin version, measure: pass@1, retry count, JaCoCo coverage, reviewer‑finding counts by severity, wall‑clock, and **token cost per task**. Run on every change; track regressions. This is what lets you A/B the §9.A router, the §B memory changes, and the §8.3 model question instead of guessing — and it's how Anthropic itself validated the multi‑agent system. Without it, the whole apparatus is unfalsifiable (§3.2).

### D. Adopt native primitives where stable; consider the Agent SDK for the orchestrator

- Move skill activation to native **`paths:`** now (stable; fixes §6.6/§6.7).
- Track #49559/#17283 and adopt **`context: fork` + `agent:`** for phase dispatch when reliable, retiring bespoke glue.
- Interoperate with / learn from Anthropic's official **`code-review`, `feature-dev`, `security-guidance`** plugins and the well‑regarded **Superpowers/GSD** and **developer-kit** rather than reimplementing.
- For a true **"Harness agent,"** the **Claude Agent SDK** (TypeScript/Python) is a more robust foundation than bash shelling `claude --print`: you own the orchestration loop, get first‑class subagents/hooks/permissions/structured outputs, and don't depend on model cooperation for control flow. This is a larger rewrite but is the architecturally honest path to "autonomous harness." (Caveat: `allowed-tools` in SKILL frontmatter doesn't apply under the SDK — control tools via `allowedTools` + `permissionMode` instead.)

### E. Modularize the monolith

Split `claudehut` into composable plugins on one marketplace: `claudehut-core` (state machine, hooks, orchestrator), `claudehut-spring` (MVC/WebFlux/JPA/R2DBC rules+skills), `claudehut-messaging` (kafka/rabbitmq/nats), `claudehut-quality` (owasp/arch-unit/coverage). This is the pattern of Anthropic's own 33 plugins (split into language‑servers / dev‑workflow / setup) and of `developer-kit` ("install only what you need"). Benefits: less skill‑listing‑budget pressure (§6.6), smaller blast radius per change (the spec/impl drift in §6 is a monolith symptom), and adoptability.

### F. DRY the guardrails

The builder guardrails live in _three_ places that must be "kept in sync" by hand (agent persona body, `--append-system-prompt` fragment, and the skill). Generate the fragment from the persona at build time and **assert equality in CI**. Hand‑synced duplication is how the spec/impl drift in §6 happened in the first place.

---

## 10. Testing — breadth ≠ behavior

375 passing assertions is genuinely impressive _as a lint suite_, and the Bash‑3.2/ref‑integrity/snapshot/perf layers are valuable guardrails. But be clear‑eyed about what's covered:

- **~L1–L5, L12–L16** (the large majority) are **static/structural**: JSON validity, frontmatter shape, file counts, section presence, reference resolution, bash syntax. These prevent _regressions in structure_, not _failures in behavior_.
- The **only behavioral coverage** is L6 (a 33‑step _simulated_ E2E with scripted artifacts — no model) and the **opt‑in** real‑Claude suite (**3 prompts**, ~$1, not in CI).

So "375/0/0" can give false confidence: the things that actually determine value — _does the workflow converge, does the generated code pass, do reviewers catch real issues, does the system get smarter_ — are barely exercised. The §4.1 nested‑dispatch and §4.2 path‑split bugs are exactly the class a structural suite _cannot_ catch, because they only manifest when real subagents run.

**Action:** the §9.C eval harness _is_ the missing test layer. Additionally, expand the real‑Claude E2E (it can't stay 3 prompts) and add a behavioral test for the reviewer fleet that asserts dispatches appear in the transcript (catches §4.1) and that a write‑via‑verify / read‑via‑state.sh round‑trips (catches §4.2).

---

## 11. Closing assessment

ClaudeHut is the work of a strong systems engineer who understands Claude Code more deeply than most plugin authors — the artifact‑derived state machine, the harness‑enforcement thesis, the stub‑commit insight, the Bash‑3.2 discipline, and (above all) the honest self‑documentation are the real thing. The thesis that **enforcement belongs in the harness, not in model goodwill** is correct and validated by the platform community.

The plugin's problems are not random sloppiness; they are **systematic consequences of two choices**: (1) building a maximally‑complex system before proving a simpler one insufficient, and (2) applying a research‑grade multi‑agent topology to coding, the domain Anthropic specifically flags as a poor fit for it. Those choices produce the cost profile (§8), the maintainability strain (§6/§9.E), the reviewer‑fleet fragility (§4.1), and a "learning" layer that isn't (§7).

The encouraging part: **none of the P0/P1 issues require abandoning the design.** Flatten the reviewer dispatch, fix the two path/decision splits, add a token cap, replace `head -200` with relevance retrieval + an outcome signal, add an eval harness, introduce adaptive depth, and modularize — and ClaudeHut becomes what the user actually wants: a governed, _measurably_ improving harness that spends its tokens where they pay off and gets smarter in a way you can prove. The bones are good; the next version should be _smaller, measured, and adaptive_ rather than larger.

---

### Appendix — source map (paraphrased; verify against originals)

**Claude Code docs**

- Skills: `context: fork`, `agent:`, `paths:`, `disable-model-invocation` (also blocks preload), `allowed-tools` (CLI‑only), skill content lifecycle (25k‑token re‑attach budget / 5k per skill after compaction), skill‑listing budget = ~1% context window, description cap 1,536 chars, bundled `/code-review` `/loop` `/debug` `/run` `/verify` `/run-skill-generator` — https://code.claude.com/docs/en/skills
- Subagents: `skills:` controls startup _injection_ not _access_; filesystem skill discovery (#32910); `--agent` for whole‑session persona — https://code.claude.com/docs/en/sub-agents
- Hooks: 27 events (v2.1.141+); `PreToolUse` uses `hookSpecificOutput.permissionDecision`; most events use top‑level `decision`; exit‑2 vs JSON semantics — https://code.claude.com/docs/en/hooks
- SDK skills/subagents/hooks (for §9.D) — https://platform.claude.com/docs/en/agent-sdk/

**Anthropic engineering**

- _Building Effective Agents_ (workflow vs agent; 5 patterns; "start simple") — https://www.anthropic.com/research/building-effective-agents
- _How we built our multi‑agent research system_ (15× tokens; "less effective for tightly interdependent tasks such as coding"; no circuit breakers; token≈80% / model≈5% of variance; pin versions) — referenced across Anthropic's engineering writeup and secondary analyses
- _Effective context engineering for AI agents_ (just‑in‑time retrieval; structured note‑taking; durable memory = only what constrains future reasoning; context rot) — https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents

**`anthropics/claude-code` issues (validate current status before acting)**

- #25834 — plugin subagent `skills:` preload silently fails (macOS) _(Path B rationale)_
- #29441 — `skills:` not preloaded for CLI‑process‑spawned teammates _(Path B has the same gap)_
- #27736 — skills _are_ injected for in‑process Task subagents; only the Task description omits them
- #16616 — user‑level skills load full body; plugin skills load frontmatter‑only _(packaging is correct)_
- #40459 — since v2.1.84 subagents lose CLAUDE.md (`tengu_slim_subagent_claudemd`)
- #4182, #61993 — nested Task/Agent spawning unsupported _(§4.1)_
- #49106 — rule degradation across multi‑subagent sessions; harness injection is the fix _(validates the thesis)_
- #49559, #17283 — `context: fork` + `agent:` not honored in some versions
- #57249 — Stop‑hook gate that can't succeed → 3‑stop‑hook loop _(§5.3)_
- #20931 — custom agents sometimes not discovered as Task subagent types
- #46727 / #43286 / #46099 — Opus 4.x degradation; subagents returning unverified data _(multi‑agent multiplies hallucination surface)_

**Competitive landscape (for §9.D/E)**

- Anthropic official marketplace: ~101 plugins (Mar 2026), 33 Anthropic‑built incl. `feature-dev`, `code-review`, `security-guidance`, `frontend-design`, 12 language servers
- _Superpowers_ (Anthropic‑listed): GSD lifecycle + TDD + brainstorm/subagent‑dev/code‑review/debug/skill‑authoring
- _developer-kit_ (giuseppe‑trisciuoglio): modular, spec‑driven, Java/TS/Python, "install only what you need," `/specs:brainstorm`
- _maestro-orchestrate_: 22 subagents, 4‑phase; _Manifest_: cost observability; _claude-mem_: semantic memory
