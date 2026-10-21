#!/usr/bin/env bash
# kb-maintain.sh — Summer KB install / self-heal for a consumer service (pack org-summer). Run ASYNC at session start:
# by scripts/maintain.sh of the single claudehut plugin, or by the org-summer plugin's own SessionStart hook in the
# split distribution (docs/v0.20 07 §2, M2b). Self-contained: no kernel library, so it runs from either plugin.
# First install (a Summer consumer without a KB) runs here. Staleness is a stamp comparison only: the KB's summerCommit vs the source's (sibling java-common-ms: its
#    git HEAD; no sibling: the bundled snapshot), plus "a build file is newer than the stamp" (the Summer module set
#    may have changed). A stale KB — or, in java-common-ms itself, a source stamp behind HEAD — is refreshed by a
#    detached `install_summer_kb.py --if-stale` (an async hook is killed under -p).
#
# Env: PROJECT_DIR (default CLAUDE_PROJECT_DIR), PLANE (default: the project's .claudehut/, else .claude/claudehut/).
# Initialized plane only (PROJECT.md). Exit 0 always; failures go to <plane>/state/hook-errors.log.
set -uo pipefail
case "$0" in */*) _here="${0%/*}" ;; *) _here="." ;; esac
_here="$(cd "$_here" 2>/dev/null && pwd)" || exit 0
PROJECT_DIR="${PROJECT_DIR:-${CLAUDE_PROJECT_DIR:-$PWD}}"
if [ -z "${PLANE:-}" ]; then
  if [ -d "$PROJECT_DIR/.claudehut" ]; then PLANE="$PROJECT_DIR/.claudehut"; else PLANE="$PROJECT_DIR/.claude/claudehut"; fi
fi
command -v jq >/dev/null 2>&1 || exit 0
hc_log() { [ -d "$PLANE/state" ] || return 0; printf '%s kb-maintain %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${*:0:260}" >> "$PLANE/state/hook-errors.log" 2>/dev/null; return 0; }

KB_DIR="$PROJECT_DIR/.claude/summer-kb"; KB_META="$KB_DIR/.summer-kb-meta.json"
KB_INSTALL="$_here/install_summer_kb.py"
KB_BUNDLE_META="$_here/../references/summer-kb/.bundle-meta.json"
if [ -f "$PLANE/PROJECT.md" ] && command -v python3 >/dev/null 2>&1 && [ -f "$KB_INSTALL" ]; then
  kb_lib=""; kb_d="$PROJECT_DIR"
  for _ in 1 2 3 4 5 6 7 8; do
    [ -f "$kb_d/java-common-ms/.claude/summer-kb/INDEX.md" ] && { kb_lib="$kb_d/java-common-ms"; break; }
    [ "$kb_d" = "${kb_d%/*}" ] || [ -z "${kb_d%/*}" ] && break
    kb_d="${kb_d%/*}"
  done
  kb_src=""
  if [ -n "$kb_lib" ]; then
    kb_src="$(GIT_OPTIONAL_LOCKS=0 git -C "$kb_lib" rev-parse -q --verify HEAD 2>/dev/null)" || kb_src=""
  elif [ -f "$KB_BUNDLE_META" ]; then
    kb_src="$(jq -r '.summerCommit // empty' "$KB_BUNDLE_META" 2>/dev/null)" || kb_src=""
  fi
  kb_stale=""
  if [ -n "$kb_lib" ] && [ "$(cd "$kb_lib" 2>/dev/null && pwd -P)" = "$(cd "$PROJECT_DIR" 2>/dev/null && pwd -P)" ]; then
    # The KB home: nothing to install, only its own stamp to keep in line with HEAD.
    [ -n "$kb_src" ] && [ "$(jq -r '.summerCommit // empty' "$KB_META" 2>/dev/null)" != "$kb_src" ] && kb_stale=1
  elif [ -f "$KB_META" ]; then
    inst="$(jq -r '.summerCommit // empty' "$KB_META" 2>/dev/null)" || inst=""
    if [ -n "$kb_src" ] && [ "$inst" != "$kb_src" ]; then kb_stale=1
    else
      kb_new="$(find "$PROJECT_DIR" -maxdepth 3 \( -name '*.gradle' -o -name '*.gradle.kts' -o -name '*.toml' \) \
          -not -path '*/build/*' -not -path '*/.claude/*' -newer "$KB_META" -print 2>/dev/null | head -1)" || kb_new=""
      [ -n "$kb_new" ] && kb_stale=1
    fi
  else
    # -exec, not `| xargs`: a project path with a space must not split. Captured, not tested in a pipeline: with
    # pipefail an early-exiting `head` would make a real match read as a miss.
    kb_hit="$(find "$PROJECT_DIR" -maxdepth 3 \( -name '*.gradle*' -o -name '*.versions.toml' \) -not -path '*/build/*' -not -path '*/.claude/*' \
        -exec grep -l 'io\.f8a\.summer:' {} + 2>/dev/null | head -1)" || kb_hit=""
    if [ -n "$kb_hit" ]; then
      python3 "$KB_INSTALL" "$PROJECT_DIR" >/dev/null 2>&1 || hc_log "summer-kb install failed"
    fi
  fi
  if [ -n "$kb_stale" ]; then
    ( nohup python3 "$KB_INSTALL" "$PROJECT_DIR" --if-stale </dev/null >/dev/null 2>&1 & ) </dev/null >/dev/null 2>&1 \
      || hc_log "summer-kb refresh could not start"
  fi
fi
exit 0
