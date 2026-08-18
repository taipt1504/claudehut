# ClaudeHut — Canonical Plugin Review (fan-out)

> This is the **main, standing review prompt** for the ClaudeHut Claude Code plugin.
> Re-run it on every release. Fill the two `<...>` fields, attach the repo, and run.

## HOW TO RUN

- **Primary (ultracode fan-out):** dispatch one independent review agent per LANE (single-level dispatch only — no nested sub-dispatch). Each agent reads the actual repo, stays in its lane, returns a structured report. Then run the **INTEGRATION AGENT**.
- **Single-agent fallback (e.g. Codex):** run the lanes sequentially in one session, then do the INTEGRATION step yourself.
- The **REGRESSION CHECKLIST** guards previously-found issues; lanes stay open for new ones.

## TARGET

- Repo / source: `/Users/taiphan/Documents/Projects/lab/claudehut`
- Target Claude Code version: `v0.5.0`
- Plugin: **ClaudeHut** — Claude Code plugin for Java/Spring backend engineers.
- Workflow: 7 phases — **Discover → Brainstorm → Spec → Plan → Build → Loop → Learn**.
- Domain stack the plugin must serve: Spring Boot 3, WebFlux/Project Reactor, R2DBC + PostgreSQL, reactor-kafka, strict non-blocking reactive patterns.

---

## SHARED CONTEXT — every lane agent receives this

### Platform constraints (Claude Code). Evaluate against these. If any is outdated for the target version, say so explicitly and continue.

1. **Skills do NOT propagate into subagents.** Fresh, isolated context per subagent. To make a subagent obey a skill, its contract must be **inlined into the dispatch prompt** (or the subagent told to read a specific static file). A doc that says "subagent uses skill X" without an injecting prompt = unenforced.
2. **`AskUserQuestion` is filtered inside subagents.** A subagent's only channel back is its final text return. Question-asking must be modeled as a **structured status** the controller re-dispatches on.
3. **Nested subagent dispatch is unsupported.** All dispatch is single-level, controller-orchestrated.
4. **CLAUDE.md is not inherited into subagents** (changed ~v2.1.84). Nothing reaching a subagent may assume it.
5. **Hook matchers silently never fire if the pattern doesn't match the real event payload** (regex/glob vs literal filename). Trace every matcher end-to-end.
6. **SessionStart hooks can inject a bootstrap** — the only reliable forced-activation mechanism.
7. **Skill auto-trigger depends entirely on `description` frontmatter.** Vague description = unreliable activation; reliability must be measurable, not assumed.

### Native Enforcement Ladder (score every "mandatory"/"native" claim against this)

- **L0 — Documented only:** described in docs, nothing enforces it.
- **L1 — Prompt-soft:** relies on phrasing/CAPS/"MANDATORY" the model may ignore over long context.
- **L2 — Description-trigger:** a skill/agent `description` specific enough to auto-fire (reliability must be shown, not claimed).
- **L3 — Bootstrap-forced:** SessionStart hook injects a forced read/instruction.
- **L4 — Hard-gated:** a hook (PreToolUse/PostToolUse/etc.) blocks/validates/rejects deterministically — the model cannot skip it.
- **L5 — Harness-native self-direction:** the plugin's agents drive harness-native primitives so usage is automated without the user manually triggering it.
  "Native" = **L3 or above.** L0–L1 do not count as native no matter how the docs phrase it.

### Review conventions (all lanes)

- Skeptical and adversarial. **Do not trust docs/README/SKILL.md** — verify every claimed behavior against the code that enforces it.
- Each finding: `location (file:line)` · what's wrong · why it matters _on Claude Code specifically_ · concrete fix · severity **P0 (blocker) / P1 (serious) / P2 (minor)**.
- Maintain a **claim-vs-mechanism** mapping: each behavioral claim ↔ enforcing mechanism (or "NONE — unenforced") + ladder level.
- For trigger reliability, reason in **pass/k** terms (would it fire 3/3?). If not, flag it.
- Every "strength" must cite a concrete mechanism in code. No generic praise.
- A lane review with zero P0/P1 findings on a pre-1.0 plugin is presumed to have under-looked — dig deeper.

---

## REGRESSION CHECKLIST — re-verify EVERY run, do NOT assume fixed

For each item: confirm current status **with evidence (file:line / trace)**, state FIXED / PARTIAL / STILL-BROKEN, and route it to the owning lane.

- **R1 — Nested dispatch in the Phase-5 reviewer fleet.** Previously the reviewer fleet relied on a subagent dispatching its own subagents (unsupported, constraint #3). Verify all Phase-5 dispatch is single-level from the controller. (Lane 1 / 4)
- **R2 — `FileChanged` hook matcher never fires.** Previously a regex/glob matcher vs literal-filename mismatch (constraint #5) meant the hook likely never triggered. Trace the matcher against the real event payload. (Lane 2)
- **R3 — CLAUDE.md inheritance assumption in subagents.** Previously assumed CLAUDE.md reaches subagents; this changed ~v2.1.84 (constraint #4). Find anything still relying on it. (Lane 3 / 4)
- **R4 — "Reinforcement learning" is mislabeled static note-injection.** Verify whether the Learn phase actually persists state that is later retrieved and changes future behavior, or is a relabeled note dump (→ L0 for self-improvement). (Lane 6)
- **R5 — A2 `background: true` silent permission-denial risk.** Confirm production uses **A1 (single-message multi-dispatch)** — not A2, which can silently swallow permission denials. Flag any A2 path. (Lane 4 / 5)
- **R6 — Activation reliability of `claudehut-init` and backtick command-block invocation (issue #3).** Verify the init/command activation is forced (L3+) and that the P7-style evaluation would pass 3/3. (Lane 2 / 4)

---

## LANES (fan out — one agent each)

### Lane 1 — Architecture & agentic workflow

**Scope:** the six-phase workflow and overall topology. Owns **R1**.
**Key questions:** Are phase boundaries clean, with explicit handoff/state between phases? Where does cross-phase state live? Is all dispatch single-level controller-orchestrated, or does anything attempt nested dispatch? Does the workflow map onto real harness primitives?
**Trace:** phase-transition mechanism, the orchestrator, every dispatch path's depth, where artifacts/state persist between phases.

### Lane 2 — Common layer (rules / hooks / skills / agents): best-practice + native enforcement

**Owns R2, co-owns R6.**
**Key questions:** Are common-layer components structured to best practice? Is each used/enforced **natively** (rate on the ladder)? Do the common hooks actually fire?
**Trace:** every common `SKILL.md` `description` (trigger specificity / pass-k); every common hook `matcher` → real payload (fires or never-fires); every common agent definition; ladder level per component.

### Lane 3 — Domain layer (Java / Spring backend): completeness + domain-correct organization + native enforcement

**Co-owns R3.**
**Key questions:** Are domain rules/skills/agents **complete** for the stack (Spring Boot 3, WebFlux/Reactor, R2DBC/Postgres, reactor-kafka, non-blocking discipline)? What's missing? Organized per domain best practice? Are domain/test/reactive contracts **inlined into subagent dispatch prompts** (else they won't propagate), or merely referenced?
**Trace:** domain skill descriptions; whether domain contracts are inlined vs referenced in dispatch prompts; whether any domain rule is hook-gated (L4) or only documented (L0).

### Lane 4 — Enforcement & harness self-direction

**Co-owns R1, R3, R5, R6.**
**Key questions:** For every behavior labeled mandatory/native, what is its **ladder level**? Is activation forced (L3) or hoped-for (L1)? Can the plugin's agents **self-direct toward harness-native automation (L5)** so it runs without the user manually triggering, or does it depend on the human remembering commands?
**Trace:** each enforcement claim → mechanism + ladder level; the SessionStart bootstrap; any PreToolUse/PostToolUse validators; any path where the agent invokes harness-native agents/commands itself.

### Lane 5 — Tooling / MCP / external-plugin integration

**Co-owns R5.**
**Key questions:** Do declared tool calls / MCP servers / external-plugin deps cover the **architecture's** and the **Java/Spring domain's** needs (build, run, reactive test, DB, Kafka)? Wired **natively** (declared in plugin config) or assumed present? Failure mode when one is missing? Any auto-approve path that swallows denials?
**Trace:** declared MCP/tool dependencies, permission tiers (deny/ask/allow), missing-tool failure modes.

### Lane 6 — Context economy & memory / real self-improvement

**Owns R4.**
**Key questions:** Progressive disclosure or context flooding? Per-session injection cost? **Is "learning/self-improvement" real** — persisted state later retrieved that demonstrably changes behavior — or static note-injection mislabeled? Score honestly.
**Trace:** what is injected and when; the memory/notes **write path AND read path**; whether the loop actually closes (does written state alter later behavior automatically?).

### Lane 7 — Cost economics

**Key questions:** Token-efficient workflow? Cost of per-session bootstrap, per-subagent dispatch overhead, review/re-review loops. Is **model selection role-appropriate** (mechanical→cheap, review/architecture→capable)? Redundant re-reads / re-pasted context?
**Trace:** subagent invocations per task, payload size per dispatch, duplicated context, model-tier assignment per role.

### Lane 8 — Maintainability & scalability

**Key questions:** Test suite for skills/hooks? Versioning + release notes + upgrade path? Fragility to Claude Code version bumps (e.g. the v2.1.84 change)? How many components silently break on a harness update? Cost to add a new skill / new domain?
**Trace:** tests/, version metadata, hard-coded assumptions about harness internals, coupling between components.

---

## INTEGRATION AGENT (sequential, after all lanes return)

1. Merge all lane findings; **dedupe** overlaps; **reconcile contradictions** (state the resolution and why).
2. **Regression status table:** R1–R6 → FIXED / PARTIAL / STILL-BROKEN + evidence.
3. **Global scorecard:** Lanes 1–8, score /5 + native ladder level where applicable, one-line justification each.
4. **Master claim-vs-mechanism table:** claim ↔ mechanism ↔ ladder level ↔ verdict (enforced / soft / unenforced).
5. **Top P0/P1 issues**, ranked, with the single highest-leverage fix called out.
6. **Top 3 to fix first.**
7. **Verdict:** SHIP / SHIP-WITH-FIXES / DO-NOT-SHIP — one paragraph + why.

## CALIBRATION

Prefer flagging a false positive ("unverified — needs a runtime test") over silence. Do not soften severity to be polite. The bar for "native" is L3+; do not let a confident README upgrade a behavior's true ladder level.

---

Đánh giá plugin sau quá trình sử dụng:

- Ở implement 70-80% sẽ thực hiện sequence ở main agents và khi đó main agents không enforce skills, không tuân thủ rules khi implement -> output code rất tệ. Việc không sử dụng skills, tuân thủ rules, memory đã vi phạm nghiêm trọng tới principal của plugin -> cần audit deep dive, verify lại để đưa ra solution enhance để đạt được hiệu suất cao nhất
- Workflow cần nghiên cứu optimize enhance hơn lí do hiện tại với các task tương đối đơn giản những việc implement khá lâu và với issue 1 đề cập ở trên thì output cũng khá tệ -> nghiên cứu, tìm kiếm và tham khảo các top plugins để reasioning và từ đó decision được giải pháp enhance phù hợp cho plugin hiện tại
- Các docs trong task được viết ở các phase có cấu trúc rất khó review ví dụ như các docs ở `.claude/reviews/examples`, các docs tổ chức viết rất nhiều chưa thể hiện được trực quan của tài liệu đặt tả kỹ thuật -> cần nghiên cứu đưa ra các template docs mà ở đó các docs được tổ chức 1 cách liền mạch, trực quan, ngắn gọn, xúc tích, đầy đủ, chính xác và có độ tin cậy cao
- Đối với các rules, skills, agents còn khá đơn giản và chưa có được principal cốt lõi cũng như chưa đạt tới level mà plugin hướng tới -> cần nghiên cứu deep dive nâng cấp lên 1 level mới mà ở đó các rules, skills, agents là tinh tuý được chất lọc từ domains của nó, được đúc kết như là kinh nghiệm của 1 expert với hơn 20 năm kinh nghiệm trong domain mà rules, skills, agents đề cập tới. Đồng thời nghiên cứu thêm các rules, skills, agents để bổ sung hoàn thiện cho các domain mà plugin hướng tới
- Vể quản lí context memory cần nghiên cứu chuyên sâu hơn, tham khảo các nguồn tài liều offical từ anthropic, các top plugins, các blogs,... các tổ chức memory 1 cách dài hạn cho agents, đảm bảo agents càng ngày càng thông tin, càng tốt hơn
  -> Plugin luôn luôn ưu tiên tương tác với agents trong claude code một các native nhất, sử dụng tối data các native plugins, tool call, protocal,... từ claude code anthropic cung cấp. Đồng thời tìm kiếm, nghiên cứu chuyên sâu về các tài liệu, các blogs, các posts, các top plugins để có được bức tranh tổng quát nhất, phân tích, đánh giá được ưu/nhược điểm để từ đó chất lọc thông tin tinh tuý nhất để tối ưu plugin
