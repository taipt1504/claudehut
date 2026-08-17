#!/usr/bin/env bash
# SessionStart hook (matcher: startup|clear|compact).
# Injects the claudehut-workflow orchestrator + top learnings + understand-anything
# detection flag as additionalContext, before turn 1. Emits a top-level systemMessage
# (user-visible) when the codebase index is absent. Never blocks (SessionStart cannot block). See 06 §3.
set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
DIR="$PROJECT_DIR/.claude/claudehut"
in="$(cat 2>/dev/null || true)"   # SessionStart hook payload (carries session_id)

command -v jq >/dev/null 2>&1 || { echo '{}'; exit 0; }   # degrade: no context injection without jq

# W0-C (v0.11): a forked session gets a NEW session_id (cli-reference: "--fork-session | When resuming,
# create a new session ID instead of reusing the original"), so neither state/$sid.json nor
# state/$sid.snapshot.json exists and :39-41 re-arms at phase=discover — a mid-implement fork is reset.
# Whether a fork can instead INHERIT its parent's state depends on a fact the docs do not carry: the
# SessionStart input schema documents no parent_session_id / forked_from field. Capture the raw payload
# under the same flag record-failure.sh uses, so one real forked session answers it. Off by default.
if [ "${CLAUDEHUT_DEBUG_PAYLOAD:-}" = "1" ]; then
  mkdir -p "$DIR/state" 2>/dev/null || true
  printf '%s\n' "$in" >> "$DIR/state/payload-debug.SessionStart.jsonl" 2>/dev/null || true
fi

# opt #3 FALLBACK — INVOCATION reliability. The init skill's !`...` script call is flaky in headless
# (P7 measured 2/3: skill engaged but the script didn't always run). So bootstrap the plane
# DETERMINISTICALLY here, with zero model reliance: if .claude/claudehut/ is absent, run the generator
# directly (stdout suppressed so it can't corrupt this hook's JSON). The skill remains for --refresh + enrich.
WAS_ABSENT=false; [ -d "$DIR" ] || WAS_ABSENT=true
INITED=false
if $WAS_ABSENT && [ -x "$PLUGIN_ROOT/bin/claudehut-init" ]; then
  CLAUDE_PROJECT_DIR="$PROJECT_DIR" "$PLUGIN_ROOT/bin/claudehut-init" "$PROJECT_DIR" >/dev/null 2>&1 && INITED=true || true
fi

# opt #1 — ARM the write gate from turn 1. Create an initial per-session state file
# (phase=discover, reuse_scan=false) if none exists, so gate-write.sh denies production writes
# until the workflow produces reuse-scan + spec + plan. Without this the gate fails open on missing
# state and the workflow is effectively optional. gate-done.sh only enforces COMPLETION once the
# workflow is engaged, so this does not wedge non-coding sessions. Bypass: claudehut-state set-bypass true.
sid="$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null || true)"
# Issue-1 durability: a compact/resume keeps the same session_id, so the live state file (and the
# implement_skill_ok skill-rail proof in it) normally survives untouched. If the live file is GONE
# (crash, manual cleanup), restore the PreCompact snapshot rather than re-arming from scratch —
# re-arming would reset phase to discover and close the skill rail mid-task (one wasted deny).
if [ -n "$sid" ] && [ ! -f "$DIR/state/$sid.json" ] && [ -f "$DIR/state/$sid.snapshot.json" ]; then
  mkdir -p "$DIR/state" 2>/dev/null || true
  cp -f "$DIR/state/$sid.snapshot.json" "$DIR/state/$sid.json" 2>/dev/null || true
fi
if [ -n "$sid" ] && [ ! -f "$DIR/state/$sid.json" ] && [ -x "$PLUGIN_ROOT/bin/claudehut-state" ]; then
  # Arm at phase=discover — phase 1 since the v0.4 Discover split (06 §3, 11 §5); also resets the skill rail.
  CLAUDE_PROJECT_DIR="$PROJECT_DIR" "$PLUGIN_ROOT/bin/claudehut-state" --session "$sid" set-phase discover >/dev/null 2>&1 || true
fi

# ST-1: bound the state directory. 315 state files across the real repos and nothing ever removes one.
# harvest-candidates.sh reads only the CURRENT session's failures, so a staged failure file is worthless
# a week later. Age out the ephemeral sidecars; never touch the live session's own files, and never touch
# the durable stores (learnings.jsonl, reuse-index.json, MEMORY*) which live one directory up.
if [ -d "$DIR/state" ]; then
  find "$DIR/state" -maxdepth 1 -type f -mtime +7 \
    \( -name '*.failures.jsonl' -o -name '*.injected.json' -o -name '*.dispatches.jsonl' \
       -o -name '*.rules-loaded.jsonl' -o -name '*.injected-phase' -o -name '*.ua-flag' \) \
    ! -name "${sid:-__none__}.*" -delete 2>/dev/null || true
fi

# Rule-template migration (Issue 4): upgraded/new rule templates must reach EXISTING projects, not only
# fresh inits. Stamp the plugin version into the plane; on mismatch re-emit the rule tree only
# (claudehut-init --refresh-rules — never touches MEMORY/PROJECT/LANGUAGE, which users may have edited).
PV="$(jq -r '.version // empty' "$PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null || true)"
if [ -n "$PV" ] && [ -d "$DIR" ] && [ -x "$PLUGIN_ROOT/bin/claudehut-init" ]; then
  STAMP="$DIR/.plugin-version"
  if [ "$(cat "$STAMP" 2>/dev/null || true)" != "$PV" ]; then
    CLAUDE_PROJECT_DIR="$PROJECT_DIR" "$PLUGIN_ROOT/bin/claudehut-init" "$PROJECT_DIR" --refresh-rules >/dev/null 2>&1 \
      && printf '%s' "$PV" > "$STAMP" 2>/dev/null || true
    # RULE-01/17: the refresh above reports stale rules on stdout, which is discarded here because this
    # hook's stdout is its JSON contract. Re-derive the same facts read-only and carry the one-line summary
    # into systemMessage, so drift reaches a human instead of dying in /dev/null on every version bump.
    DRIFT="$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" "$PLUGIN_ROOT/bin/claudehut-init" "$PROJECT_DIR" --audit 2>/dev/null \
             | grep -m1 '^  summary:' | sed 's/^  summary: //')" || true
    case "$DRIFT" in
      ""|"0 stale, 0 missing, 0 over-budget memory file(s)") DRIFT="" ;;
    esac
  fi
fi

# Inject the DIGEST (tiers + profiles + laws + phase map), not the whole orchestrator. This block is re-paid on
# every startup|resume|clear|compact, so the full SKILL.md was the single largest recurring context cost; the
# model loads it on demand with /claudehut:claudehut-workflow. Fall back to the full file if the digest is missing.
DIGEST="$PLUGIN_ROOT/skills/claudehut-workflow/references/digest.md"
ctx="$(cat "$DIGEST" 2>/dev/null \
  || cat "$PLUGIN_ROOT/skills/claudehut-workflow/SKILL.md" 2>/dev/null \
  || echo "ClaudeHut workflow orchestrator skill not found.")"

# Top learnings (P7 helper — optional; no-op until present). WS-6: --snapshot records the injected IDs so the
# Learn phase can stamp .applied on the ones that resurface (closing the inject→use reinforcement loop).
if [ -x "$PLUGIN_ROOT/scripts/inject-learnings.sh" ] && [ -f "$DIR/learnings.jsonl" ]; then
  snap=""; [ -n "$sid" ] && { mkdir -p "$DIR/state" 2>/dev/null || true; snap="$DIR/state/$sid.injected.json"; }
  learn="$("$PLUGIN_ROOT/scripts/inject-learnings.sh" --top 12 --max-len 200 ${snap:+--snapshot "$snap"} 2>/dev/null || true)"
  [ -n "$learn" ] && ctx="$ctx"$'\n\n## Learnings for this project (top by confidence x recency x hits)\n'"$learn"
fi

# understand-anything detection — no native runtime cross-plugin field exists, so read
# enabledPlugins via the CLI. Default to "absent" when the command/data is unavailable.
# Cached PER SESSION (not persistently): the CLI spawn costs 1-5s and this hook also fires on every
# resume/clear/compact, while a persistent cache would go stale the moment the user enables the plugin.
UA_CACHE=""; [ -n "$sid" ] && UA_CACHE="$DIR/state/$sid.ua-flag"
if [ -n "$UA_CACHE" ] && [ -f "$UA_CACHE" ]; then
  ua="$(cat "$UA_CACHE" 2>/dev/null || true)"
else
  if command -v claude >/dev/null 2>&1 \
     && claude plugin list --json 2>/dev/null | jq -e '.[]? | select((.id | startswith("understand-anything@")) and (.enabled // false))' >/dev/null 2>&1; then
    ua="ENABLED — Discover MUST use its query/search skills."
  else
    ua="absent — Discover uses claudehut-explorer + Grep."
  fi
  [ -n "$UA_CACHE" ] && { mkdir -p "$DIR/state" 2>/dev/null || true; printf '%s' "$ua" > "$UA_CACHE" 2>/dev/null || true; }
fi
ctx="$ctx"$'\n\n## understand-anything: '"$ua"

# ---------------- Summer Framework KB (service-scoped, deterministic — no model reliance) ----------------
# Guarantee: a Summer consumer always has the KB pointer in context. Mirrors the plane-init fallback above:
# (a) zero-touch install when a Summer consumer has no KB; (b) self-heal when the plugin ships a newer
# bundle (summerCommit mismatch); (c) inject a compact grounding block into additionalContext.
KB_META="$PROJECT_DIR/.claude/summer-kb/.summer-kb-meta.json"
KB_INSTALL="$PLUGIN_ROOT/skills/summer-kb-setup/scripts/install_summer_kb.py"
KB_BUNDLE_META="$PLUGIN_ROOT/skills/summer-kb-setup/references/summer-kb/.bundle-meta.json"
if command -v python3 >/dev/null 2>&1 && [ -f "$KB_INSTALL" ]; then
  # (a) zero-touch: Summer deps present but no installed KB → install (bounded scan, stdout suppressed)
  if [ ! -f "$KB_META" ] \
     && find "$PROJECT_DIR" -maxdepth 3 -name '*.gradle*' -not -path '*/build/*' 2>/dev/null \
        | head -20 | xargs grep -ls 'io\.f8a\.summer:' 2>/dev/null | head -1 | grep -q .; then
    python3 "$KB_INSTALL" "$PROJECT_DIR" >/dev/null 2>&1 || true
  fi
  # (b) self-heal: installed summerCommit != bundle summerCommit → refresh from the new bundle
  if [ -f "$KB_META" ] && [ -f "$KB_BUNDLE_META" ]; then
    inst="$(jq -r '.summerCommit // empty' "$KB_META" 2>/dev/null || true)"
    bund="$(jq -r '.summerCommit // empty' "$KB_BUNDLE_META" 2>/dev/null || true)"
    if [ -n "$inst" ] && [ -n "$bund" ] && [ "$inst" != "$bund" ]; then
      python3 "$KB_INSTALL" "$PROJECT_DIR" >/dev/null 2>&1 || true
    fi
  fi
fi
# (c) inject the grounding block when a KB is installed
if [ -f "$KB_META" ]; then
  kb_mods="$(jq -r '(.includedModules // []) | join(", ")' "$KB_META" 2>/dev/null || true)"
  kb_commit="$(jq -r '.summerCommit // "unknown"' "$KB_META" 2>/dev/null || true)"
  ctx="$ctx"$'\n\n## Summer Framework KB (MANDATORY grounding — service-scoped, installed locally)\n'"This service consumes Summer (io.f8a.summer). Installed KB modules: ${kb_mods:-unknown} (summerCommit ${kb_commit:0:7})."$'\n'"When a task touches Summer — a summer-* dependency, a f8a.*/summer.* property, an auto-config gate, a Ufid/Txid annotation (@JE/@SE/@TX/@Compact/@UInt128/@UfidPrefix), a Summer Kafka contract, or any Summer type (ApiResponse, ViewableException, outbox/audit, resource-server, rate limiter) — you MUST ground the decision in .claude/summer-kb/ (start: USAGE.md → INDEX.md), not memory. Never invent property names, gate defaults, or coordinates; unverifiable facts are marked [unverified], never guessed."
fi

DRIFT="${DRIFT:-}"
need_init=false
{ $WAS_ABSENT && ! $INITED; } && need_init=true   # only prompt if absent AND the deterministic fallback couldn't run

jq -n --arg ctx "$ctx" --arg dir "$DIR" --argjson need "$need_init" --arg drift "$DRIFT" '
  {hookSpecificOutput: {hookEventName:"SessionStart", additionalContext:$ctx, watchPaths:[$dir], reloadSkills:true}}
  + (if $need
     then {systemMessage:"ClaudeHut: no codebase index found. Run /claudehut:claudehut-init to bootstrap this project before starting a task."}
     elif $drift != ""
     then {systemMessage:("ClaudeHut: rule drift after the plugin upgrade — " + $drift + ". Review with `claudehut-init --audit`.")}
     else {} end)'
