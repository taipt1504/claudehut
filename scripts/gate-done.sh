#!/usr/bin/env bash
# Stop hook — the COMPLETION GATE.
# Blocks turn end until review=pass AND phase=learn. Honors the native consecutive-Stop
# cap: when stop_hook_active is true (~8 blocks reached) it stops blocking and surfaces the
# remaining outstanding items, instead of wedging the session. Per-session state by
# hook-input session_id. FAILS OPEN on missing state. See 06 §3 / 01 §8.
set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
in="$(cat || true)"
command -v jq >/dev/null 2>&1 || exit 0   # degrade: fail open

block() { jq -n --arg r "$1" '{decision:"block",reason:$r}'; exit 0; }

# Native cap: never block past the consecutive-Stop limit.
[ "$(jq -r '.stop_hook_active // false' <<<"$in" 2>/dev/null || echo false)" = "true" ] && exit 0

sid="$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null || true)"
STATE="$PROJECT_DIR/.claude/claudehut/state/$sid.json"
[ -f "$STATE" ] || exit 0   # no active workflow for this session → don't block stop (06 §5)
s="$(cat "$STATE" 2>/dev/null || echo '{}')"
jq -e . <<<"$s" >/dev/null 2>&1 || s='{}'   # N4: a corrupt state file → treat as empty (fail open, no jq noise)

# IDEA-F10 sits ABOVE the bypass early-exit on purpose: an open bypass is the most important thing this
# advisory can report, and the exit below made it the one case the advisory could never reach.
# IDEA-F10: when the task really is done — review passed AND Learn recorded — say so once, and say what the
# session is still carrying. A finished task with 6 stale sidecars and an open bypass looks identical to a
# clean one from the model's side. systemMessage is user-facing and non-blocking (precedent: bootstrap.sh's
# missing-index prompt), so this cannot wedge the Stop path. Only fires on the fully-clean pass, never
# alongside an outstanding item.
if [ "$(jq -r '.review // empty' <<<"$s" 2>/dev/null)" = "pass" ] \
   && [ -f "$PROJECT_DIR/.claude/claudehut/state/$sid.learn-receipt.json" ] \
   && [ "$(jq -r '(.outstanding // []) | length' <<<"$s" 2>/dev/null || echo 0)" = "0" ]; then
  _byp="$(jq -r 'if .bypass then "bypass ON (" + ((.bypass_reason // "no reason recorded")) + ")" else "" end' <<<"$s" 2>/dev/null || true)"
  # `wc -l`, not `grep -c .`. grep -c prints "0" AND exits 1 when nothing matches, so the `|| echo 0`
  # fallback fired ON TOP of the 0 it had already printed: _old became the two-line string "0\n0", the
  # comparison below died with `[: 0\n0: integer expression expected`, and a Stop hook wrote to stderr on
  # every clean pass — which Claude Code surfaces to the user as "Stop hook error". The advisory itself
  # was never wrong (a real count of 3 exits 0 and compares fine); the whole cost was stderr noise on the
  # one path that should have been silent, emitted by the script that owns the completion decision.
  _old="$(find "$PROJECT_DIR/.claude/claudehut/state" -maxdepth 1 -type f -mtime +7 \
            \( -name '*.failures.jsonl' -o -name '*.injected.json' \) 2>/dev/null | wc -l | tr -d ' ')"
  case "$_old" in ''|*[!0-9]*) _old=0 ;; esac
  _msg=""
  [ -n "$_byp" ] && _msg="$_byp"
  [ "${_old:-0}" -gt 0 ] && _msg="${_msg:+$_msg; }${_old} state sidecar(s) older than 7 days"

  # ── F8: per-tier dispatch budget — ADVISORY, on its own line, NEVER a decision. ──────────────────────
  # A HARD budget here would be actively harmful: a legitimate full-tier task may need 15 dispatches, and
  # blocking it would convert a cost feature into a correctness failure. This is modelled on the platform's
  # own posture — its large-workflow warning fires at 25 agents / 1.5M tokens and is advisory: it does not
  # pause or limit the run. So: no `decision`, no `block`, nothing that alters the Stop outcome.
  #
  # It rides INSIDE the IDEA-F10 clean-pass branch on purpose, and that placement is the design:
  #   * gate-done.sh is THE completion gate. A second independent `jq -nc` emitter could put two
  #     concatenated JSON objects on stdout, and could co-occur with a real block() — extra noise beside
  #     the review==pass requirement is exactly what the plan forbids. Sharing this branch makes
  #     "never alongside an outstanding item" structural rather than something to remember.
  #   * The branch already means "the task is genuinely finished", which is when a task-end budget is due.
  #   * Accepted narrowing, stated so nobody assumes otherwise: this branch requires a learn-receipt, so a
  #     trivial-tier task that legitimately skips Learn never sees the advisory.
  # It also MUST NOT fire on a clean under-budget run or it becomes wallpaper — hence `-gt`, and hence the
  # ceilings below sit at the tier's documented maximum rather than under it.
  #
  # CEILINGS, derived from the phase→skill map in skills/claudehut-workflow/SKILL.md:92-98 at its stated
  # maxima — not guessed, because a bare number rots the same way a hardcoded price table does:
  #   full    2 discover (explorer ∥ reuse-scanner) + 1 brainstorm + 2 plan (planner + plan-reviewer)
  #           + 1 re-review after a REVISE + 12 implement (≤3 parallel per phase × 4 phases)
  #           + 12 review (≤6 auditors × the ≤2-loop body cap) + 1 learn                          = 31
  #   small   0 discover/brainstorm/spec/plan (inline or full-tier only) + 6 implement (≤3 × 2 phases)
  #           + 12 review + 1 learn                                                               = 19
  #   trivial 0 deliberation phases + 3 implement + 6 review (one auditor round) + 0 learn         =  9
  #
  # The count comes from `claudehut-state cost-report --count`, NOT from `wc -l` on the ledger: that reader
  # joins start↔stop on agent_id and discards unmatched stops. Counting records instead would let the
  # measured orphan stop (v0.11 M5 — one emitted during compaction, fresh agent_id, empty agent_type)
  # inflate the number and fire this advisory on a clean run, which is the one thing it must never do.
  # Whole thing is guarded and defaults to 0: this script runs `set -euo pipefail` and BLOCKS, so a missing
  # binary or an unreadable ledger must cost the gate nothing.
  _bud=""
  _tier="$(jq -r '.complexity // "full"' <<<"$s" 2>/dev/null || echo full)"
  case "$_tier" in trivial) _ceil=9 ;; small) _ceil=19 ;; *) _ceil=31 ;; esac
  _disp="$( { "$PLUGIN_ROOT/bin/claudehut-state" cost-report --session "$sid" --count 2>/dev/null; } || echo 0 )"
  case "$_disp" in ''|*[!0-9]*) _disp=0 ;; esac
  if [ "$_disp" -gt "$_ceil" ]; then
    _bud="ClaudeHut advisory (not a gate, nothing was blocked): $_disp subagent dispatches this session vs the $_tier-tier guide of $_ceil. See where they went: claudehut-state cost-report --session $sid"
  fi

  _out=""
  [ -n "$_msg" ] && _out="ClaudeHut: task complete. Session still carries — $_msg."
  [ -n "$_bud" ] && _out="${_out:+$_out$'\n'}$_bud"
  if [ -n "$_out" ]; then
    jq -nc --arg m "$_out" '{systemMessage:$m}'
  fi
fi
[ "$(jq -r '.bypass // false' <<<"$s")" = "true" ] && exit 0

review="$(jq -r '.review // "pending"' <<<"$s")"
phase="$(jq -r '.phase // "discover"' <<<"$s")"
reuse="$(jq -r '.reuse_scan // false' <<<"$s")"
spec="$(jq -r '.spec_path // empty' <<<"$s")"
plan="$(jq -r '.plan_path // empty' <<<"$s")"
tier="$(jq -r '.complexity // "full"' <<<"$s")"   # trivial skips Learn (tier map) — gate must match
profile="$(jq -r '.profile // empty' <<<"$s")"     # WS-7 task shape — decides the deliverable rail

# opt #1: the SessionStart hook ARMS state (phase=discover) so the write gate denies production
# writes from turn 1. But only enforce COMPLETION once the workflow was actually ENGAGED — a freshly
# armed session that never did workflow work (no reuse-scan, no spec/plan, still discover/brainstorm) must not
# block turn end, so non-coding sessions stay usable. Writing production code requires engaging the
# workflow (the write gate forces it), and once engaged this gate requires it to finish.
engaged=false
{ [ "$reuse" = "true" ] \
  || { [ -n "$spec" ] && [ "$spec" != null ]; } \
  || { [ -n "$plan" ] && [ "$plan" != null ]; } \
  || [ "$phase" = plan ] || [ "$phase" = implement ] || [ "$phase" = review ] || [ "$phase" = learn ] \
  || [ "$profile" = audit ] || [ "$profile" = investigation ]; } && engaged=true   # WS-7 M2: declaring an audit/investigation shape IS engagement (a pure audit may never set reuse-scan or advance past discover)
[ "$engaged" = true ] || exit 0

# WS-7: audit/investigation produce a FINDINGS deliverable, not production code — so the code-review gate
# (review==pass) does not apply. Completion requires a findings.md artifact (the profile-aware deliverable
# rail) plus, on a non-trivial tier, the universal Learn pass. This is the genuine adaptivity: the same
# "done" gate MEANS something different per task shape, not just a different label.
if [ "$profile" = "audit" ] || [ "$profile" = "investigation" ]; then
  # WS-7 M1: check THIS task's RECORDED findings (set-findings), not a glob that any prior task satisfies.
  fp="$(jq -r '.findings_path // empty' <<<"$s")"
  fok=false
  if [ -n "$fp" ] && [ "$fp" != null ]; then
    case "$fp" in /*) fpp="$fp" ;; *) fpp="$PROJECT_DIR/$fp" ;; esac
    [ -f "$fpp" ] && fok=true
  fi
  if [ "$fok" != true ]; then
    block "ClaudeHut gate: profile=$profile — the deliverable is a findings report, not code. Write the audit's conclusions + file:line evidence to tasks/NNNN-<slug>/findings.md and record it: claudehut-state set-findings <that path>."
  fi
  if [ "$tier" != "trivial" ]; then
    RECEIPT="$PROJECT_DIR/.claude/claudehut/state/$sid.learn-receipt.json"
    [ -f "$RECEIPT" ] || block "ClaudeHut gate: findings produced but no learn-receipt this session — run claudehut:capture-learnings before finishing."
  fi
  exit 0
fi

# The reason must name the NEXT action, not the LAST gate. This block used to emit one sentence —
# "run claudehut:review until the outstanding set is empty" — at EVERY phase, which was wrong twice over:
#
#   * At discover/brainstorm/spec/plan it ordered the model to jump 2-4 phases ahead. The gate whose whole
#     purpose is to stop the workflow being skipped was itself instructing the skip.
#   * It named an exit condition that was ALREADY SATISFIED. `outstanding` is empty for the entire run-up
#     to Review, so "until the outstanding set is empty" describes the current state; a model reading it
#     literally has no way to comply, and the real terminal condition (`set-review pass`, which demands an
#     evidence file with a coverage table) went unstated.
#
# Phase order per tier is read off the tier map in skills/claudehut-workflow/SKILL.md: trivial and small
# skip Brainstorm/Spec/Plan, trivial also skips Learn.
next_step() {
  case "$phase" in
    discover)
      if [ "$tier" = trivial ] || [ "$tier" = small ]; then
        printf 'Next: claudehut:implement (phase 5) — the %s tier skips Brainstorm/Spec/Plan.' "$tier"
      else
        printf 'Next: claudehut:brainstorm (phase 2).'
      fi ;;
    brainstorm) printf 'Next: claudehut:write-spec (phase 3).' ;;
    spec)       printf 'Next: claudehut:write-plan (phase 4).' ;;
    plan)       printf 'Next: claudehut:implement (phase 5).' ;;
    implement)  printf 'Next: claudehut:review (phase 6).' ;;
    review)     printf 'Next: finish claudehut:review — merge the auditor findings into review.md.' ;;
    *)          printf 'Next: continue the workflow from phase %s.' "$phase" ;;
  esac
}
nout="$(jq -r '(.outstanding // []) | length' <<<"$s" 2>/dev/null || echo 0)"
case "$nout" in ''|*[!0-9]*) nout=0 ;; esac
# Only offered before Implement. Past that point code exists, so "this was never a coding task" is not a
# live reading and the line would just be noise on the gate that matters.
shape_hint=""
case "$phase" in discover|brainstorm|spec)
  shape_hint=" If this is not a coding task, record its shape instead of walking the code phases: claudehut-state set-profile investigation (or audit), then set-findings <path to findings.md>." ;;
esac

if [ "$review" = "capped" ]; then
  # `capped` is claudehut:review (SKILL.md:142) declaring its 2-round fix loop exhausted and handing the
  # survivors to the user. The old text told it to "run claudehut:review until outstanding is empty",
  # i.e. straight back into the loop the cap exists to stop — the round cap and the completion gate
  # contradicting each other. It still BLOCKS: `set-review capped` takes no evidence, so letting it
  # satisfy the gate would turn the cap into a free escape hatch. Only the instruction changes.
  block "ClaudeHut gate: review is CAPPED, not passed — the fix loop hit its 2-round limit, so do NOT dispatch another review round. Surface the ${nout} surviving outstanding item(s) to the user and get a decision: fix them, defer each with a written justification, or have the USER run claudehut-state set-bypass true --reason '<why>'."
elif [ "$review" != "pass" ]; then
  if [ "$nout" -gt 0 ]; then
    _o="${nout} outstanding item(s) still recorded"
  else
    _o="review has not been recorded as passed"
  fi
  block "ClaudeHut gate: the workflow is engaged and this task is not finished — phase=${phase}, tier=${tier}, ${_o}. $(next_step) The gate opens only on: claudehut-state set-review pass --evidence tasks/NNNN-<slug>/review.md (the artifact must carry a real coverage table + test counts; a flag with no evidence is refused).${shape_hint}"
elif [ "$tier" != "trivial" ] && [ "$phase" != "learn" ]; then
  # trivial tier legitimately skips Learn (workflow tier map) — blocking it here would wedge the
  # session until the consecutive-Stop cap. full + small still require the Learn pass.
  block "ClaudeHut gate: Learn pass not run — run claudehut:capture-learnings before finishing."
elif [ "$tier" != "trivial" ] && [ "$phase" = "learn" ]; then
  # WS-6: phase=learn is necessary but not sufficient. The fictional old check ("learnings.jsonl non-empty")
  # passed on ANY prior line. The real proof a Learn pass ran THIS task is a per-session learn-receipt
  # (written by merge-learnings / the inline learn path) NEWER than this task's reuse-scan (the first artifact
  # every task produces in Discover). Fail-open: if the reuse-scan path is unavailable, require only that the
  # receipt exists — never wedge on unexpected state.
  RECEIPT="$PROJECT_DIR/.claude/claudehut/state/$sid.learn-receipt.json"
  if [ ! -f "$RECEIPT" ]; then
    block "ClaudeHut gate: no learn-receipt for this session — capture-learnings did not run its merge this task. Run claudehut:capture-learnings before finishing."
  else
    art="$(jq -r '.reuse_scan_artifact // empty' <<<"$s")"
    if [ -n "$art" ] && [ "$art" != null ]; then
      case "$art" in /*) artp="$art" ;; *) artp="$PROJECT_DIR/$art" ;; esac
      if [ -f "$artp" ] && [ "$artp" -nt "$RECEIPT" ]; then
        block "ClaudeHut gate: the learn-receipt is stale (older than this task's reuse-scan) — Learn ran for a PRIOR task, not this one. Re-run claudehut:capture-learnings for the current task."
      fi
    fi
  fi
fi

exit 0
