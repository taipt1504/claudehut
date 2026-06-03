# ClaudeHut Design — 06. Hooks

> Part of the **ClaudeHut** design document set. See [README](./README.md). Hook bindings are fixed in [02 §4.4](./02-architecture.md#44-hooks--see-06).
> **Status:** Design v1 · **Pillar focus:** P1 (enforcement), P5 (persistence), P6 (native). **Native mechanism:** plugin `hooks/hooks.json` + the hook I/O protocol.

Hooks are ClaudeHut's only **deterministic** enforcement — they are code, not model judgment, so they cannot be rationalized away. This document specifies each hook's event, matcher, the JSON it reads, the JSON/exit-code it returns, and — stated honestly — **exactly what it can and cannot enforce**.

## Table of Contents

- [1. The hook I/O protocol (what we rely on)](#1-the-hook-io-protocol-what-we-rely-on)
- [2. hooks.json (the manifest)](#2-hooksjson-the-manifest)
- [3. Hook specs](#3-hook-specs)
  - [bootstrap.sh — SessionStart](#bootstrapsh--sessionstart)
  - [inject-phase.sh — UserPromptSubmit](#inject-phasesh--userpromptsubmit)
  - [gate-write.sh — PreToolUse (action gate)](#gate-writesh--pretooluse-action-gate)
  - [format-java.sh — PostToolUse](#format-javash--posttooluse)
  - [gate-done.sh — Stop (completion gate)](#gate-donesh--stop-completion-gate)
  - [verify-subagent.sh — SubagentStop](#verify-subagentsh--subagentstop)
  - [persist-state.sh — PreCompact](#persist-statesh--precompact)
- [4. What hooks honestly can and cannot do](#4-what-hooks-honestly-can-and-cannot-do)
- [5. Failure modes and escape hatches](#5-failure-modes-and-escape-hatches)

---

## 1. The hook I/O protocol (what we rely on)

Every hook process receives a JSON payload on stdin and signals decisions via **exit code** and/or **structured JSON on stdout**:

| Signal | Meaning |
|--------|---------|
| exit `0` + JSON stdout | success; JSON is processed |
| exit `2` | **blocking** error; for pre-events the action/turn is blocked, stderr is fed to Claude |
| other non-zero | non-blocking; logged only, execution continues |

The structured outputs ClaudeHut uses:

- `PreToolUse` → `hookSpecificOutput.permissionDecision: "deny"` + `permissionDecisionReason` + `additionalContext`.
- `Stop` / `SubagentStop` → `decision: "block"` + `reason`.
- `SessionStart` / `UserPromptSubmit` → `hookSpecificOutput.additionalContext` (and for SessionStart: `watchPaths`, `reloadSkills`); `systemMessage` (top-level, user-visible) for bootstrap prompts.

All scripts live in `${CLAUDE_PLUGIN_ROOT}/scripts/` and read project state from the **per-session** file `${CLAUDE_PROJECT_DIR}/.claude/claudehut/state/<session_id>.json`, where `<session_id>` comes from the hook-input `session_id` field — this per-session keying is the concurrency fix in [01 §4.1](./01-agentic-workflow.md#41-concurrency-and-worktree-isolation-collision-safe-state). They **never write the state file** — the only writer is `bin/claudehut-state` ([01 §4](./01-agentic-workflow.md#4-the-phase-state-machine)).

Where each hook fires across the session/turn lifecycle:

```mermaid
flowchart TB
    SS["SessionStart<br/>bootstrap.sh"] --> T0{{"turn loop"}}
    T0 --> UPS["UserPromptSubmit<br/>inject-phase.sh"]
    UPS --> PRE["PreToolUse(Write/Edit)<br/>gate-write.sh — ACTION GATE"]
    PRE --> POST["PostToolUse(*.java)<br/>format-java.sh"]
    POST --> SUB["SubagentStop<br/>verify-subagent.sh"]
    SUB --> STOP["Stop<br/>gate-done.sh — COMPLETION GATE"]
    STOP -->|allow| T0
    STOP -.->|block: review not pass or learn missing| UPS
    T0 -.->|context fills| PC["PreCompact<br/>persist-state.sh"]
    classDef gate fill:#fde,stroke:#b36;
    class PRE,STOP gate;
```

## 2. hooks.json (the manifest)

```json
{
  "hooks": {
    "SessionStart": [
      { "matcher": "startup|clear|compact",
        "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/scripts/bootstrap.sh", "timeout": 15 }] }
    ],
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/scripts/inject-phase.sh", "timeout": 10 }] }
    ],
    "PreToolUse": [
      { "matcher": "Write|Edit|MultiEdit",
        "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/scripts/gate-write.sh" }] }
    ],
    "PostToolUse": [
      { "matcher": "Write|Edit",
        "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/scripts/format-java.sh",
                    "if": "Edit(*.java)|Write(*.java)", "async": true }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/scripts/gate-done.sh" }] }
    ],
    "SubagentStop": [
      { "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/scripts/verify-subagent.sh" }] }
    ],
    "PreCompact": [
      { "hooks": [{ "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/scripts/persist-state.sh", "async": true }] }
    ]
  }
}
```

Referenced from `plugin.json` via `"hooks": "./hooks/hooks.json"`.

## 3. Hook specs

Each: **Event · Matcher · Reads · Returns · Enforces · Phase · Honest limits**.

### bootstrap.sh — SessionStart
- **Event/Matcher:** `SessionStart` on `startup|clear|compact`.
- **Reads:** `source`, `cwd`; checks for `${CLAUDE_PROJECT_DIR}/.claude/claudehut/` (the prerequisite index); reads `enabledPlugins` from the settings hierarchy (or runs `claude plugin list`) to **detect the `understand-anything` plugin**.
- **Returns:** `additionalContext` = the `claudehut-workflow` orchestrator body **+ top-N learnings** (parsed from `learnings.jsonl`, ranked by confidence×recency) **+ the plugin-detection flag** (`understand-anything: enabled|absent`, which the `claudehut:brainstorm` skill's explore step branches on). Sets `watchPaths` to the `.claude/claudehut/` dir and `reloadSkills: true` after a fresh Bootstrap. **Arms the gate (opt #1):** also writes an initial `state/<session_id>.json` (`phase=brainstorm`, `reuse_scan=false`) for this session if none exists, so `gate-write.sh` is live from turn 1 — without this the write gate fails open until the agent *voluntarily* starts the workflow (measured gap: agents skipped it, see EVAL-REPORT #2). **Auto-bootstraps the plane (opt #3 fallback):** when `.claude/claudehut/` is **absent**, it runs `bin/claudehut-init` directly (stdout suppressed) to generate the project plane deterministically — the skill's `!`backtick`` invocation was measured **flaky (2/3)** in P7, so bootstrap removes the model from invocation entirely. If that fallback could not run, emits a top-level `systemMessage` prompting the user to run `/claudehut:init`.
- **Enforces:** the Workflow is loaded **before turn 1** (non-optional); the agent starts each session primed with this project's learnings (P5 read-path); and the conditional understand-anything integration is resolved **here**, because there is no native runtime cross-plugin branch ([01 §3](./01-agentic-workflow.md#3-prerequisite-the-codebase-index-not-a-phase)).
- **Phase:** all (entry) + the Bootstrap prerequisite.
- **Honest limits:** only affects context at session start; cannot enforce anything later in the session. Plugin detection is a **hook-script read of settings**, not a native declarative dependency.
- **Pseudo-logic:**
  ```bash
  payload=$(cat); dir="$CLAUDE_PROJECT_DIR/.claude/claudehut"
  ctx=$(cat "$CLAUDE_PLUGIN_ROOT/skills/claudehut-workflow/SKILL.md")
  if [ -f "$dir/learnings.jsonl" ]; then
    ctx="$ctx\n\n## Learnings for this project\n$("$CLAUDE_PLUGIN_ROOT/scripts/inject-learnings.sh" --top 12)"
  fi
  # cross-plugin detection (no native runtime branch exists) — read enabledPlugins
  if claude plugin list --json 2>/dev/null | jq -e '.[] | select(.name=="understand-anything" and .enabled)' >/dev/null; then
    ctx="$ctx\n\n## understand-anything: enabled — Brainstorm MUST use its query/search skills."
  else
    ctx="$ctx\n\n## understand-anything: absent — Brainstorm uses claudehut-explorer + Grep."
  fi
  # emit systemMessage if deterministic fallback could not run
  need_init=false
  { [ ! -d "$dir" ] && ! $INITED; } && need_init=true
  jq -n --arg ctx "$ctx" --argjson need "$need_init" '
    {hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx,watchPaths:[$dir],reloadSkills:true}}
    + (if $need then {systemMessage:"ClaudeHut: no codebase index found. Run /claudehut:init to bootstrap this project."} else {} end)'
  ```

### inject-phase.sh — UserPromptSubmit
- **Event/Matcher:** `UserPromptSubmit` (all).
- **Reads:** `prompt`, `state.json`.
- **Returns:** `additionalContext` = "Current phase: `<phase>`. Next allowed step: `<…>`." plus up to ~5 learnings whose `trigger` keyword-matches the prompt (targeted retrieval).
- **Enforces:** every turn re-anchors to the current phase and surfaces relevant prior learnings — keeps the Workflow salient across a long session and feeds the reuse instinct.
- **Phase:** all.
- **Honest limits:** advisory context only; does not block. (Blocking lives in the gate hooks.)

### gate-write.sh — PreToolUse (action gate)
- **Event/Matcher:** `PreToolUse` on `Write|Edit|MultiEdit`.
- **Reads:** `tool_input.file_path`; the per-session state file `state/<session_id>.json` (keyed by the hook-input `session_id`) — fields `reuse_scan`, `spec_path`, `plan_path`, `phase`, `bypass`.
- **Returns:** on violation, `permissionDecision: "deny"` + `permissionDecisionReason` naming what's missing + `additionalContext` telling the agent which skill to run. On pass, no decision (allow).
- **Enforces (the P4 hard gate):** **no new production code until the reuse-scan artifact, the spec, and the plan all exist** — and (opt #4) until the recorded artifact **files actually exist under `.claude/claudehut/`**, not just the state flags. This is an **action gate** — it blocks the write keystroke, deterministically.
- **Phase:** boundary of Brainstorm/Spec/Plan → Implement.
- **Honest limits:** it gates *writes to production paths only*; it deliberately **allows** writes to `.claude/claudehut/**` (so reuse-scan/spec/plan files can be created) and to test paths during TDD's RED step. It cannot force the agent to *think well* — only to have produced the artifacts.
- **Pseudo-logic:**
  ```bash
  in=$(cat); sid=$(jq -r '.session_id' <<<"$in")
  s=$(cat "$CLAUDE_PROJECT_DIR/.claude/claudehut/state/$sid.json" 2>/dev/null || echo '{}')  # missing → {} → fails open (allow)
  fp=$(jq -r '.tool_input.file_path' <<<"$in")
  case "$fp" in *".claude/claudehut/"*|*"/test/"*|*"Test.java"|*"IT.java") allow ;; esac
  [ "$(jq -r '.bypass' <<<"$s")" = "true" ] && allow
  # opt #4: a recorded path must EXIST as a file under .claude/claudehut/ to satisfy the gate
  exists() { p="$1"; case "$p" in /*) :;; *) p="$CLAUDE_PROJECT_DIR/$p";; esac
             case "$p" in *"/.claude/claudehut/"*) [ -f "$p" ];; *) false;; esac; }
  if [ "$(jq -r '.reuse_scan' <<<"$s")" != "true" ]; then
    deny "Run claudehut:brainstorm first (reuse-scan step) — no reuse-scan artifact for this task."
  elif ! exists "$(jq -r '.reuse_scan_artifact' <<<"$s")"; then
    deny "reuse-scan flag set but no artifact file under .claude/claudehut/ — write it there."
  elif [ "$(jq -r '.spec_path' <<<"$s")" = "null" ]; then
    deny "Write the spec first — run claudehut:write-spec."
  elif ! exists "$(jq -r '.spec_path' <<<"$s")"; then
    deny "spec recorded but file missing under .claude/claudehut/ — write it to tasks/NNNN-<slug>/spec.md."
  elif [ "$(jq -r '.plan_path' <<<"$s")" = "null" ]; then
    deny "Write a plan first — run claudehut:write-plan."
  elif ! exists "$(jq -r '.plan_path' <<<"$s")"; then
    deny "plan recorded but file missing under .claude/claudehut/ — write it to tasks/NNNN-<slug>/plan.md."
  fi
  ```
  (`deny`/`allow` emit the `permissionDecision` JSON.)

### format-java.sh — PostToolUse
- **Event/Matcher:** `PostToolUse` on `Write|Edit`, `if: Edit(*.java)|Write(*.java)`, `async: true`.
- **Reads:** `tool_input.file_path`.
- **Returns:** nothing blocking (async, non-blocking exit).
- **Enforces:** consistent formatting via `google-java-format`/`palantir-java-format` so the reviewer agents never waste signal on style nits.
- **Phase:** Implement.
- **Honest limits:** cosmetic only; runs after the edit, never blocks it.

### gate-done.sh — Stop (completion gate)
- **Event/Matcher:** `Stop` (all).
- **Reads:** the per-session state file `state/<session_id>.json` (keyed by the hook-input `session_id`) — fields `review`, `phase`, `bypass` — and the hook input field `stop_hook_active`.
- **Returns:** on violation, `decision: "block"` + `reason` ("Review not passed" or "Learn not run"). Otherwise allow.
- **Enforces (the discipline gate):** **the agent may not end its turn claiming done until `review=pass` AND the Learn pass has run** — but (opt #1 engaged-guard) only once the workflow is **engaged** (reuse-scan done, or a spec/plan recorded, or phase past brainstorm). A freshly *armed* brainstorm session that did no workflow work is not blocked, so non-coding sessions stay usable while the write gate remains armed. This is the superpowers "verification-before-completion" rule made deterministic, extended to the Review compliance loop.
- **Phase:** Review → Learn boundary.
- **Honest limits:** `Stop` fires at **turn end**, not on every intra-turn phase change — so it enforces *completion order*, not *mid-turn* ordering (that's the skills' Iron Laws). It is also **capped natively**: Claude Code blocks at most ~8 consecutive `Stop` hooks (`stop_hook_active`). So the Review loop ([01 §8](./01-agentic-workflow.md#8-the-review-loop-and-its-exit-condition)) cannot block forever — when the cap is hit, this hook **degrades gracefully**: it stops blocking, leaves `review=capped`, and surfaces the remaining `outstanding` items to the user.
- **Pseudo-logic:**
  ```bash
  in=$(cat); sid=$(jq -r '.session_id' <<<"$in")
  s=$(cat "$CLAUDE_PROJECT_DIR/.claude/claudehut/state/$sid.json" 2>/dev/null || echo '{}')
  [ "$(jq -r '.bypass' <<<"$s")" = "true" ] && exit 0
  # honor the native consecutive-Stop cap — never wedge the session
  [ "$(jq -r '.stop_hook_active' <<<"$in")" = "true" ] && exit 0   # cap reached → allow, surface outstanding
  r=$(jq -r '.review' <<<"$s"); p=$(jq -r '.phase' <<<"$s")
  # opt #1 engaged-guard: don't enforce completion on an armed-but-unused session
  engaged=$(jq -r 'if (.reuse_scan==true) or (.spec_path!=null) or (.plan_path!=null)
                   or (.phase|IN("plan","implement","review","learn")) then "y" else "n" end' <<<"$s")
  [ "$engaged" = y ] || exit 0
  if [ "$r" != "pass" ]; then block "Review not passed — run claudehut:review until outstanding is empty (with fresh evidence)."
  elif [ "$p" != "learn" ]; then block "Learn pass not run — run claudehut:capture-learnings before finishing."
  fi
  ```

### verify-subagent.sh — SubagentStop
- **Event/Matcher:** `SubagentStop` (all; can match on `agent_type`). *(The script verifies subagent **output** — it is named for the verb, not the retired phase.)*
- **Reads:** `agent_type`, transcript path.
- **Returns:** `decision: "block"` if a file-producing phase subagent returned without its required artifact: `claudehut-reuse-scanner` must produce `tasks/*/reuse-scan.md` (legacy `reuse-scan-*.md` also accepted); `claudehut-planner` must produce `tasks/*/plan.md` (legacy `plans/*.md` also accepted). Review auditors return findings as text and are not file-checked here.
- **Enforces:** subagents complete their contract — an auditor/scanner/planner can't return empty-handed and let the main thread proceed on a false premise.
- **Phase:** Brainstorm/Plan/Review.
- **Honest limits:** can only check for the artifact's existence/shape, not its quality.

### persist-state.sh — PreCompact
- **Event/Matcher:** `PreCompact` (all), `async: true`.
- **Reads:** `state.json`, in-flight learnings.
- **Returns:** non-blocking.
- **Enforces (P5 durability):** flush any pending learnings to `learnings.jsonl` and snapshot `state.json` before context is compacted, so a long session that compacts mid-task does not lose its phase position or learnings.
- **Phase:** all.
- **Honest limits:** best-effort; relies on the agent having staged learnings.

## 4. What hooks honestly can and cannot do

A consolidated truth table (the advisor's correctness requirement):

| Goal | Right hook | Can it? |
|------|-----------|---------|
| Load the workflow before turn 1 | `SessionStart` `additionalContext` | ✅ yes |
| Block writing new code before reuse-scan + spec + plan | `PreToolUse` `deny` | ✅ yes (blocks the action) |
| Block "I'm done" before `review=pass` + Learn | `Stop` `block` | ✅ yes (blocks turn end) |
| Loop Review *forever* until compliant | `Stop` `block` | ⚠️ bounded — Claude blocks at most ~8 consecutive `Stop`s (`stop_hook_active`); the loop degrades to "surface remaining items" at the cap |
| Force test-before-code *within* a turn | — (no hook) | ❌ no — that's the `tdd` Iron Law (skill, in-context) |
| Force the agent to *reason well* | — | ❌ no — hooks gate actions, not thought quality |
| Branch on whether another plugin is installed | `SessionStart` hook reading `enabledPlugins` | ⚠️ only via a hook script — no native runtime cross-plugin field exists |
| Persist learnings across sessions | `PreCompact` + Learn-phase writes + `memory: project` | ✅ yes |

Mid-turn phase ordering is **not** a hook capability and the design never claims it is; ordering inside a turn is the job of the orchestrator + Iron-Law skills ([04 §5](./04-skills.md#5-enforcement-skills-iron-laws)).

## 5. Failure modes and escape hatches

- **`jq`/`bash` missing:** scripts probe for `jq` and degrade to non-blocking (exit 0) if absent — gates fail *open*, never wedging the user. (Roadmap [10](./10-build-roadmap.md) hardens this.)
- **Missing / stale / mismatched-key state file:** the gates **fail open** (allow / don't block) when `state/<session_id>.json` is absent, stale (each entry carries `ts`; state older than a configurable window = "no task in progress"), or keyed under a session id that doesn't match. This is deliberate — never wedge the user — but it means a writer/reader `session_id` mismatch would *silently disable enforcement*; the enforcement-critical gates run on the main thread (same session as the writer) so they agree by construction, and the build gate-tests assert key agreement ([01 §4.1](./01-agentic-workflow.md#41-concurrency-and-worktree-isolation-collision-safe-state)). **Since opt #1**, the SessionStart hook arms an initial state file, so within a ClaudeHut session the write gate is active *by construction* rather than relying on the agent to start the workflow; fail-open now covers only genuine missing/torn-state and non-ClaudeHut sessions, not the "agent skipped the workflow" case (which previously slipped through — EVAL-REPORT #2).
- **Explicit bypass:** `state.json.bypass=true` (set only via `/claudehut:phase --force` → `bin/claudehut-state`) disables the two gate hooks for the session; recorded for audit.
- **Review-loop cap (native):** the `Stop` consecutive-block cap (`stop_hook_active`) is itself a safety valve — `gate-done.sh` honors it and surfaces remaining `outstanding` items rather than blocking forever ([01 §8](./01-agentic-workflow.md#8-the-review-loop-and-its-exit-condition)).
- **Global off switch:** the user's `disableAllHooks` setting turns everything off — ClaudeHut does not fight native settings (P6).

---

**Prev:** [← 05. Rules](./05-rules.md) · **Next:** [07. Memory Architecture →](./07-memory-architecture.md)
