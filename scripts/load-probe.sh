#!/usr/bin/env bash
# Authoritative plugin LOAD probe (EVAL-REPORT #1 / audit A.2).
#
# `claude plugin validate` only checks marketplace.json — it did NOT catch the P6
# over-declare bug that broke runtime load. The authoritative check is to actually
# load the plugin headlessly and inspect the system/init event.
#
# WHAT THIS ASSERTS, AND WHY IT CHANGED (W22).
#
# v0.10 gated on `plugin_errors == []`, read as `jq '.plugin_errors // []'`. That gate was VACUOUS:
# the system/init event has no `plugin_errors` key at all. Measured on Claude Code 2.1.234, the
# complete key set is
#
#   agents  analytics_disabled  apiKeySource  capabilities  claude_code_version  cwd
#   fast_mode_disabled_reason  fast_mode_state  mcp_servers  messaging_socket_path  model
#   output_style  permissionMode  plugins  product_feedback_disabled  session_id  skills
#   slash_commands  subtype  terminal_slash_commands  tools  type  uuid
#
# so the `// []` default converted "field missing" into "field says everything is fine", and the probe
# reduced to `loaded >= 1` while printing "PASS - plugin loads cleanly". That is the same defect class
# v0.11 found twice: PostToolUseFailure's absent `tool_error` object and SessionStart's 5-key payload.
#
# Asserting the key's PRESENCE instead — the obvious repair — would fail 100% of runs on this runtime,
# which is worse than useless on a release-checklist step. So the gate moved to what the event actually
# carries: the COMPONENT ROSTER. `agents`, `skills` and `slash_commands` each list claudehut's
# components under their plugin-scoped names. That is a strictly stronger check than the old one, and
# it is the check the probe was written for: an over-declare drops components from the roster, which is
# exactly how P6 broke runtime load. The expected sets are DERIVED from the tree, so adding an agent or
# a skill needs no edit here — a component that fails to load is named in the diff.
#
# Set CLAUDEHUT_DEBUG_PAYLOAD=1 to dump the raw init event; that is how the key set above was measured,
# and it is how the next schema change gets caught rather than absorbed.
#
# Needs the `claude` CLI + a working auth session, so it is a release-checklist /
# local step, not a public-CI step. Exit 0 iff the plugin loads cleanly.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok(){  PASS=$((PASS+1)); echo "  ok   - $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL - $1"; }

command -v claude >/dev/null 2>&1 || { echo "FAIL - claude CLI not found"; exit 2; }
command -v jq     >/dev/null 2>&1 || { echo "FAIL - jq not found"; exit 2; }

echo "== load-probe: claude -p --plugin-dir $ROOT =="
# --verbose is required for stream-json under -p, and </dev/null keeps the CLI from consuming this
# script's stdin (the defect that made trigger-eval.sh measure one query three times).
out="$(claude -p "noop — load probe, do nothing" \
        --plugin-dir "$ROOT" \
        --output-format stream-json --verbose </dev/null 2>/dev/null || true)"

# The system/init event carries the loaded-plugin roster and every component the runtime registered.
init="$(printf '%s\n' "$out" | jq -c 'select(.type=="system" and .subtype=="init")' 2>/dev/null | head -1)"
if [ -z "$init" ]; then
  echo "FAIL - no system/init event in stream (probe could not start)"
  exit 1
fi

if [ "${CLAUDEHUT_DEBUG_PAYLOAD:-0}" = "1" ]; then
  echo "  --- raw system/init event (CLAUDEHUT_DEBUG_PAYLOAD=1) ---"
  printf '%s' "$init" | jq . 2>/dev/null || printf '%s\n' "$init"
  echo "  --- end raw event ---"
fi

# ---- the plugin itself -------------------------------------------------------------------------
entry="$(printf '%s' "$init" | jq -c '[.plugins[]?] | map(select(.name=="claudehut")) | first // empty' 2>/dev/null)"
if [ -n "$entry" ]; then
  ok "claudehut present in plugins[] ($(printf '%s' "$entry" | jq -r '.source // "?"'))"
else
  bad "claudehut absent from plugins[] — the plugin did not load at all"
fi

# The runtime reports the version it actually loaded. A stale cache is the single most common cause of
# "the fix is in the repo but the behaviour did not change" (13 of 15 installs run stale plugin code).
want_v="$(jq -r '.version // empty' "$ROOT/.claude-plugin/plugin.json" 2>/dev/null)"
got_v="$(printf '%s' "$entry" | jq -r '.version // empty' 2>/dev/null)"
if [ -n "$want_v" ] && [ "$got_v" = "$want_v" ]; then
  ok "runtime loaded version $got_v (matches plugin.json)"
else
  bad "version mismatch: plugin.json says '${want_v:-?}', runtime loaded '${got_v:-none}'"
fi

# ---- the component roster ----------------------------------------------------------------------
# Every expectation is derived from the tree, so this needs no edit when a component is added.
roster_diff() { # $1 label, $2 expected newline list, $3 actual newline list
  local label="$1" missing extra
  missing="$(comm -23 <(printf '%s\n' "$2" | sort -u) <(printf '%s\n' "$3" | sort -u) | tr '\n' ' ')"
  extra="$(  comm -13 <(printf '%s\n' "$2" | sort -u) <(printf '%s\n' "$3" | sort -u) | tr '\n' ' ')"
  missing="${missing%% }"; extra="${extra%% }"
  if [ -z "${missing// }" ] && [ -z "${extra// }" ]; then
    ok "$label: all $(printf '%s\n' "$2" | grep -c . ) registered"
  else
    [ -n "${missing// }" ] && bad "$label: NOT registered by the runtime —$missing"
    [ -n "${extra// }"   ] && bad "$label: runtime registered names the tree does not have —$extra"
  fi
}

exp_agents="$(for f in "$ROOT"/agents/*.md; do [ -e "$f" ] && echo "claudehut:$(basename "$f" .md)"; done)"
act_agents="$(printf '%s' "$init" | jq -r '[.agents[]?|select(startswith("claudehut:"))]|.[]' 2>/dev/null)"
roster_diff "agents" "$exp_agents" "$act_agents"

exp_skills="$(for d in "$ROOT"/skills/*/; do [ -f "$d/SKILL.md" ] && echo "claudehut:$(basename "$d")"; done)"
act_skills="$(printf '%s' "$init" | jq -r '[.skills[]?|select(startswith("claudehut:"))]|.[]' 2>/dev/null)"
roster_diff "skills" "$exp_skills" "$act_skills"

exp_cmds="$(for f in "$ROOT"/commands/*.md; do [ -e "$f" ] && echo "claudehut:$(basename "$f" .md)"; done)"
act_cmds="$(printf '%s' "$init" | jq -r '[.slash_commands[]?|select(startswith("claudehut:"))]|.[]' 2>/dev/null)"
# slash_commands carries both commands/ and skills/; only the commands half is asserted here.
act_cmds="$(comm -12 <(printf '%s\n' "$exp_cmds" | sort -u) <(printf '%s\n' "$act_cmds" | sort -u))"
roster_diff "commands" "$exp_cmds" "$act_cmds"

# ---- plugin_errors: reported, never gated ------------------------------------------------------
# Kept as a forward tripwire. If a future runtime starts emitting the key, its contents show up here
# and the next author can promote it back to a gate on evidence rather than on hope.
if printf '%s' "$init" | jq -e 'has("plugin_errors")' >/dev/null 2>&1; then
  pe="$(printf '%s' "$init" | jq -c '.plugin_errors' 2>/dev/null)"
  if [ "$pe" = "[]" ]; then ok "plugin_errors is present and empty"
  else bad "plugin_errors reports: $pe"; fi
else
  echo "  note - this runtime ($(printf '%s' "$init" | jq -r '.claude_code_version // "?"')) emits no plugin_errors key; the roster diff above is the gate"
fi

echo
echo "LOAD-PROBE: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
echo "PASS - plugin loads cleanly"
