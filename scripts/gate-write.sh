#!/usr/bin/env bash
# PreToolUse hook (matcher: Write|Edit|MultiEdit) — the ACTION GATE.
# Denies new production code until: reuse_scan=true AND spec_path set AND plan_path set
# AND (skill rail, every tier) claudehut:implement was INVOKED for this task.
# Always allows: writes under .claude/claudehut/**, test paths, and when bypass=true.
# Per-session state keyed by hook-input session_id. FAILS OPEN on a missing state file
# (allows) — deliberate, never wedge the user; see 06 §5 / 01 §4.1.
set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
in="$(cat || true)"
command -v jq >/dev/null 2>&1 || exit 0   # degrade: fail open

allow() { exit 0; }   # no decision = proceed normally
# permissionDecisionReason alone reaches the model; also sending it as additionalContext paid for the same
# text twice on a path that fires on every denied production write.
deny()  { jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'; exit 0; }

sid="$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null || true)"

# Real CC payload carries the target at top-level .tool_input.file_path for Write, Edit
# AND MultiEdit (MultiEdit applies many edits to ONE file). The prior branch read
# .tool_input.file_edits[] — a field that does NOT exist in the CC payload — so it
# produced an empty list and let EVERY MultiEdit bypass the gate (fail-open). Extract the
# top-level path and also tolerate per-edit nested paths from any shape, so the gate
# applies regardless of the exact payload. Empty list → all_exempt stays true → fail-open
# (06 §5), unchanged. NB: exact MultiEdit shape pending a live payload dump — this is
# correct under every observed/claimed shape.
fp_list="$(jq -r '[.tool_input.file_path, (.tool_input.edits[]?.file_path), (.tool_input.file_edits[]?.file_path)] | map(select(. != null and . != "")) | .[]' <<<"$in" 2>/dev/null || true)"
fp="$(printf '%s\n' "$fp_list" | head -1)"

# Resolve "." / ".." / duplicate slashes WITHOUT requiring the file to exist (the target is usually a new
# file, so realpath/readlink -f are unusable here). Pure bash 3.2 — this runs on every Write/Edit.
canon_path() {
  local p="$1" out="" seg rest
  case "$p" in /*) : ;; *) p="$PROJECT_DIR/$p" ;; esac
  rest="$p"
  while [ -n "$rest" ]; do
    seg="${rest%%/*}"
    if [ "$seg" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
    case "$seg" in
      ''|.) : ;;
      ..)   out="${out%/*}" ;;
      *)    out="$out/$seg" ;;
    esac
  done
  printf '%s' "${out:-/}"
}

# Non-production targets are always allowed (reuse-scan/spec/plan files; tests during TDD RED).
# For MultiEdit: ALL paths in the batch must be exempt for the call to bypass the gate.
# Empty fp_list (malformed payload) keeps all_exempt=true and falls through to allow — fail-open (06 §5).
#
# Matched on the CANONICAL path against anchored patterns, not raw substrings. The old
# `*"/.claude/claudehut/"*|*"/test/"*` form exempted two things it never meant to:
#   - any production class under a package component named `test` (src/main/java/com/acme/test/Pay.java)
#   - any path traversing out through an exempt substring (.claude/claudehut/../../../src/main/java/X.java)
# Both reached ALLOW against an armed gate. exists_canon() below shares canon_path for the same reason.
all_exempt=true
while IFS= read -r p; do
  [ -z "$p" ] && continue
  cp_="$(canon_path "$p")"
  # Order matters: production sources are excluded FIRST, so the test patterns below can stay broad without
  # re-opening the `src/main/java/com/acme/test/Pay.java` hole. Naming a package `test` no longer buys an
  # exemption, but every real test layout keeps one.
  case "$cp_" in
    */.claude/claudehut/*) : ;;                                               # workflow artifacts
    */src/main/*) all_exempt=false; break ;;                                  # production code, whatever it is named
    */src/*[Tt]est*/*) : ;;                                                   # src/test, integrationTest, testFixtures,
                                                                              # commonTest, jvmTest, androidTest, functionalTest
    */src/it/*|*/test/*|*/tests/*) : ;;                                       # sbt/failsafe it, and non-JVM test roots
    *Test.java|*Tests.java|*IT.java|*Test.kt|*Spec.kt|*Spec.scala) : ;;       # test classes by name
    *_test.go|*_test.py|*.spec.ts|*.test.ts|*.spec.js|*.test.js) : ;;
    *) all_exempt=false; break ;;
  esac
done <<<"$fp_list"
$all_exempt && allow

STATE="$PROJECT_DIR/.claude/claudehut/state/$sid.json"
[ -f "$STATE" ] || allow   # no active workflow for this session → fail open (06 §5)
s="$(cat "$STATE" 2>/dev/null || echo '{}')"
jq -e . <<<"$s" >/dev/null 2>&1 || s='{}'   # N4: a corrupt state file → treat as empty (fail open, no jq noise)

[ "$(jq -r '.bypass // false' <<<"$s")" = "true" ] && allow

reuse="$(jq -r '.reuse_scan // false' <<<"$s")"
art="$(jq -r '.reuse_scan_artifact // empty' <<<"$s")"
spec="$(jq -r '.spec_path // empty' <<<"$s")"
plan="$(jq -r '.plan_path // empty' <<<"$s")"
tier="$(jq -r '.complexity // "full"' <<<"$s")"   # trivial|small|full; default full = no skipping

# opt #4: a recorded artifact must actually EXIST as a file under .claude/claudehut/ — a set flag
# pointing at a missing or non-canonical path does NOT open the gate.
# Canonicalised, not merely absolutised: a recorded artifact path of the form
# `.claude/claudehut/../../src/main/java/Evil.md` used to satisfy the substring test while the file it names
# lives in the production tree, which opened the gate on artifacts stored outside the store.
exists_canon() {
  local p="$1"; [ -n "$p" ] && [ "$p" != null ] || return 1
  p="$(canon_path "$p")"
  case "$p" in */.claude/claudehut/*) [ -f "$p" ] && return 0 ;; esac
  return 1
}

# SAFE-BY-CONSTRUCTION fast lane (Issue 4): the model proposes the tier via set-complexity, but the GATE
# verifies the tier's bound deterministically — it can't be talked past these checks. The fast lane skips
# only the DELIBERATION phases (Spec/Plan); the reuse-scan rail above is required in EVERY tier.
FAST_MAX_FILES="${CLAUDEHUT_FAST_MAX_FILES:-2}"
# changed production files this session = tracked-modified ∪ untracked ∪ the incoming write target
fastlane_bound_ok() {
  command -v git >/dev/null 2>&1 || return 1          # can't verify → deny fast lane (force full)
  local changed rel sensitive count
  rel="$(canon_path "$fp")"; rel="${rel#$PROJECT_DIR/}"   # canonical, so a traversal path is counted in the form it resolves to
  changed="$( { ( cd "$PROJECT_DIR" && git diff --name-only 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null ); printf '%s\n' "$rel"; } \
    | grep -vE '(^|/)\.claude/|(/test/|Test\.java$|IT\.java$)' | sort -u | grep -vE '^$' )"
  count="$(printf '%s\n' "$changed" | grep -cE '.' || true)"
  [ "$count" -le "$FAST_MAX_FILES" ] || { FAIL_REASON="touches $count files (fast-lane cap $FAST_MAX_FILES)"; return 1; }
  # sensitive surface → never fast-lane (false-skip of security/migration review = shipped defect)
  sensitive="$(printf '%s\n' "$changed" | grep -Ein 'security|/auth|SecurityConfig|migration|db/changelog|V[0-9].*__.*\.sql|flyway|liquibase' || true)"
  [ -z "$sensitive" ] || { FAIL_REASON="touches a security/auth/migration path"; return 1; }
  return 0
}

# Skill rail (all tiers, Issue 1): production writes require that claudehut:implement was actually
# INVOKED for this task — proven by implement_skill_ok, which ONLY record-skill.sh (PreToolUse on the
# Skill tool) sets, and which set-phase discover|brainstorm resets at each task boundary. Artifact
# checks alone measured a 69% bypass (11/16 real tasks wrote production code with zero Skill(implement)
# calls — losing the Iron Law, the rules table, and the dispatch discipline in one skip). Checked in
# BOTH branches below (fast lane + full tier) before their allow, after the phase-order denials so the
# deny messages still arrive in workflow order (reuse → spec → plan → skill).
skill_ok="$(jq -r '.implement_skill_ok // false' <<<"$s")"
require_skill() {
  [ "$skill_ok" = "true" ] && return 0
  deny "ClaudeHut gate: artifacts are ready but claudehut:implement has not been invoked for this task. Invoke the Skill tool with skill=claudehut:implement (one call — it loads the Iron Law, the tech-stack rules table, and the parallel-dispatch discipline), then retry this write. (If you DID just invoke it and still see this, the recorder hook failed — check jq is installed and run: claudehut-state --session <sid> mark-skill implement.)"
}

# Rail 1 (all tiers): reuse-scan must exist.
if [ "$reuse" != "true" ]; then
  deny "ClaudeHut gate: run claudehut:discover first (its reuse-scan step) — no reuse-scan artifact for this task (think-and-reuse before build)."
elif ! exists_canon "$art"; then
  deny "ClaudeHut gate: reuse-scan flag set but no artifact file under .claude/claudehut/ (got: ${art:-none}). Write it under .claude/claudehut/tasks/NNNN-<slug>/reuse-scan.md."
fi

# Fast lane (trivial|small): skip Spec/Plan, but only if the deterministic bound holds.
# The skill rail applies HERE TOO — the fast lane skips deliberation phases, never the implement skill
# (it is the fast lane's only carrier of test-first + the rules table; one Skill call, no subagent).
if [ "$tier" = "trivial" ] || [ "$tier" = "small" ]; then
  if fastlane_bound_ok; then require_skill; allow; fi
  deny "ClaudeHut gate: complexity=$tier fast lane denied — ${FAIL_REASON}. Escalate to the full workflow: claudehut-state set-complexity full, then run claudehut:write-spec + claudehut:write-plan."
fi

# Full tier: require spec + plan (deliberation phases).
if [ -z "$spec" ] || [ "$spec" = "null" ]; then
  deny "ClaudeHut gate: write the implementation spec first — run claudehut:write-spec."
elif ! exists_canon "$spec"; then
  deny "ClaudeHut gate: spec recorded but file not found under .claude/claudehut/ (got: $spec). Write it in the task dir .claude/claudehut/tasks/NNNN-<slug>/spec.md, not a bare specs/ path."
elif [ -z "$plan" ] || [ "$plan" = "null" ]; then
  deny "ClaudeHut gate: write the plan first — run claudehut:write-plan."
elif ! exists_canon "$plan"; then
  deny "ClaudeHut gate: plan recorded but file not found under .claude/claudehut/ (got: $plan). Write it in the task dir .claude/claudehut/tasks/NNNN-<slug>/plan.md."
fi
require_skill
allow
