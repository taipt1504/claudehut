#!/usr/bin/env bash
# InstructionsLoaded hook — the rule-load ledger.
#
# Records which rule/instruction files the runtime ACTUALLY loaded, so the enforcement set stops being a
# purely model-authored claim. Review declares an enforcement set in Brainstorm; nothing has ever checked it
# against what the harness really put in context. This ledger is the ground truth for that comparison.
#
# Advisory and ADDITIVE: the observed set augments the declared one, never replaces it. A rule that loaded but
# was not declared is a gap worth surfacing; a rule declared but not observed may simply not have matched a
# path glob yet. Neither blocks.
#
# Sidecar: .claude/claudehut/state/<sid>.rules-loaded.jsonl (ephemeral; claudehut-init gitignores state/)
set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
in="$(cat || true)"
command -v jq >/dev/null 2>&1 || exit 0

sid="$(jq -r '.session_id // empty' <<<"$in" 2>/dev/null || true)"
fp="$(jq -r '.file_path // empty' <<<"$in" 2>/dev/null || true)"
reason="$(jq -r '.load_reason // empty' <<<"$in" 2>/dev/null || true)"   # the field is load_reason, not reason
[ -n "$sid" ] && [ -n "$fp" ] || exit 0

DIR="$PROJECT_DIR/.claude/claudehut/state"
mkdir -p "$DIR" 2>/dev/null || exit 0
F="$DIR/$sid.rules-loaded.jsonl"

# This hook runs ASYNCHRONOUSLY, so several instances append at once. A single SHORT O_APPEND write does not
# interleave in practice, but that is a property of the write staying inside one buffer, not the PIPE_BUF
# guarantee (which governs pipes, not regular files). Measured with 60 concurrent writers: ~561 B lines gave 0
# corrupt lines, ~1681 B lines gave 6 spliced, invalid-JSON lines. So the length is CAPPED below rather than
# assumed — a rule path is normally ~60 B, but nothing stopped a pathological one from silently corrupting a
# ledger a later version is meant to trust. No lock: that exists for read-modify-write, which this is not.
fp="${fp:0:400}"; reason="${reason:0:64}"   # keep the record well inside one buffered write
line="$(jq -nc --arg p "$fp" --arg r "$reason" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{ts:$t, file_path:$p, load_reason:$r}' 2>/dev/null || true)"
[ -n "$line" ] && printf '%s\n' "$line" >> "$F" 2>/dev/null
exit 0
