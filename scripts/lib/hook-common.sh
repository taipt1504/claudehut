# shellcheck shell=bash
# hook-common.sh — the v0.12 hook contract, in one place (05-hooks.md §2, ADR-H4).
#
#   K1 always exit 0      trap hc_exit EXIT returns 0 on every path. NO `set -e` / `set -u` here or in a caller:
#                         an unbound variable exits 1 without running an ERR trap, which surfaces as "hook error".
#   K2 ≤1 JSON on stdout  hc_ctx / hc_sysmsg only ASSIGN (first value wins); hc_exit is the only printer, and it
#                         builds the object in pure bash, so a broken or missing jq can never corrupt stdout.
#   K3 errors are silent  a non-zero exit or HC_FAILED drops the pending output and logs one line (≤300 B) to
#                         state/hook-errors.log; stderr of the whole hook goes to the same log.
#   K4 no decision fields there is deliberately no function that can emit decision / permissionDecision /
#                         updatedInput / continue, or exit 2.
#   K7 no plane → exit 0  hc_plane_or_exit is pure bash up to the plane test and creates nothing when absent.
#   K8 read-only state    hooks never write state/<sid>.json or task.json; dedupe goes to state/<sid>.nudged[.<key>].
#
# Callers: source this file, run hc_init, then hc_plane_or_exit. Functions that "return 1" for a normal
# negative (hc_active_task, hc_rel, hc_in_scope, hc_once) must be called inside if / && / || — as a bare
# statement a non-zero return would fire the ERR trap and be logged as a failure.

HC_IN=""; HC_EVENT=""; HC_CTX=""; HC_SYS=""; HC_FAILED=""; HC_BUDGET="${HC_BUDGET:-500}"
HC_SID=""; HC_TASK=""; HC_TASK_ID=""; HC_REL=""; PLANE=""; HUB=""; HC_LANG="en"; HC_HEAD=""; HC_INDEXED=""
HC_NAME="${0##*/}"

hc_init() {
  PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
  PROJECT_DIR="${PROJECT_DIR%/}"; [ -n "$PROJECT_DIR" ] || PROJECT_DIR="/"
  HC_IN="$(cat 2>/dev/null)"
  set -o pipefail
  trap 'hc_exit' EXIT
  trap 'HC_FAILED=$?; exit "$HC_FAILED"' ERR   # keep the failing command's status: hc_exit logs it (K3)
}

hc_log() { # one line, ≤300 B, only when a plane exists (no plane → create nothing)
  [ -n "$PLANE" ] && [ -d "$PLANE/state" ] || return 0
  local line
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) $HC_NAME $*"
  printf '%s\n' "${line:0:300}" >> "$PLANE/state/hook-errors.log" 2>/dev/null
  return 0
}

hc_plane_or_exit() {
  PLANE="$PROJECT_DIR/.claude/claudehut"
  [ -d "$PLANE" ] || { PLANE=""; exit 0; }
  command -v jq >/dev/null 2>&1 || exit 0
  # Not inside a `{ …; } 2>/dev/null` group: bash restores the group's fds when it ends, undoing the exec.
  [ -d "$PLANE/state" ] || mkdir -p "$PLANE/state" 2>/dev/null   # a fork per hook run only on the first one
  if [ -d "$PLANE/state" ] && [ -w "$PLANE/state" ] \
     && { [ ! -e "$PLANE/state/hook-errors.log" ] || [ -w "$PLANE/state/hook-errors.log" ]; }; then
    exec 2>>"$PLANE/state/hook-errors.log"
  else
    exec 2>/dev/null   # K3 on a read-only plane (mounted / checked-out hub): no log to reach, so stay silent (HC2-2)
  fi
  # One jq read of topology.json serves both the hub and the language (ADR-R7: plane → hub.json (M6) → en).
  HUB=""; HC_LANG=""
  if [ -f "$PLANE/topology.json" ]; then
    # \x1f, not a tab: IFS whitespace collapses, so an empty hub would shift the language into HUB.
    IFS=$'\x1f' read -r HUB HC_LANG <<<"$(jq -r '[(.hub // "" | tostring), (.language // "" | tostring)] | join("\u001f")' \
      "$PLANE/topology.json" 2>/dev/null)" || :
  fi
  [ -z "${CLAUDEHUT_HUB:-}" ] || HUB="$CLAUDEHUT_HUB"
  [ -n "$HUB" ] || HUB="$PLANE"
  if [ "$HC_LANG" != vi ] && [ "$HC_LANG" != en ] && [ "$HUB" != "$PLANE" ]; then
    # Same order and hub.json locations as scripts/index/memory.py resolve_language (04 AC14).
    local hb="$HUB" hf
    case "$hb" in /*) : ;; *) hb="$PROJECT_DIR/$hb" ;; esac
    for hf in "$hb/.claude/claudehut/hub/hub.json" "$hb/hub.json"; do
      [ -f "$hf" ] || continue
      HC_LANG="$(jq -r '.language // empty | strings' "$hf" 2>/dev/null)" || HC_LANG=""
      case "$HC_LANG" in vi|en) break ;; esac
    done
  fi
  case "$HC_LANG" in vi|en) : ;; *) HC_LANG=en ;; esac
  HC_SID="$(jq -r '.session_id // empty' <<<"$HC_IN" 2>/dev/null)" || HC_SID=""
  hc_safe_id "$HC_SID" || HC_SID=""
  return 0
}

hc_safe_id() { # a value that is about to become a path component
  case "$1" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

# state/<sid>.json .active_task → tasks/<id>/task.json. Missing schema:2 (v0.11 state, bypass=true files),
# corrupt JSON, a closed task or a dangling pointer all mean "no active task".
hc_active_task() {
  HC_TASK=""; HC_TASK_ID=""
  [ -n "$HC_SID" ] || return 1
  local sf="$PLANE/state/$HC_SID.json" id tf
  [ -f "$sf" ] || return 1
  id="$(jq -r 'if type=="object" and .schema==2 then (.active_task // empty) else empty end' "$sf")" || return 1
  hc_safe_id "$id" || return 1
  tf="$PLANE/tasks/$id/task.json"
  [ -f "$tf" ] || return 1
  # A task another session resumed is that session's, even through this session's stale pointer (04 §3).
  HC_TASK="$(jq -c --arg s "$HC_SID" 'if type=="object" and .schema==2 and ((.status // "active")=="active")
      and ((.session // $s)==$s) then . else empty end' "$tf")" \
    || { HC_TASK=""; return 1; }
  [ -n "$HC_TASK" ] || return 1
  HC_TASK_ID="$id"
  return 0
}

# A plane claudehut-init actually generated (not a bare .claude/claudehut/ some tool created). v0.11 planes
# have no topology.json, so PROJECT.md is the marker.
hc_plane_initialized() { [ -f "$PLANE/PROJECT.md" ]; }

# HC_HEAD = the commit HEAD of repo $1 (default $PROJECT_DIR) names, in pure bash (05 §2: .git/HEAD → ref →
# packed-refs, `gitdir:` followed for a worktree; no git spawn — the UserPromptSubmit fast path, 07 §7). The
# argument is for M6, which checks each hub repo. Return 1 for no repo or an unborn branch.
hc_head() {
  HC_HEAD=""
  local r="${1:-$PROJECT_DIR}" g h="" ref line cd_=""
  g="$r/.git"
  if [ -f "$g" ]; then   # worktree / submodule: ".git" is a file holding "gitdir: <path>"
    IFS= read -r line < "$g" || [ -n "$line" ] || return 1
    case "$line" in "gitdir: "*) g="${line#gitdir: }" ;; *) return 1 ;; esac
    case "$g" in /*) : ;; *) g="$r/$g" ;; esac
  fi
  [ -f "$g/HEAD" ] || return 1
  if [ -f "$g/commondir" ]; then   # refs and packed-refs live in the main repo's git dir
    IFS= read -r cd_ < "$g/commondir" || [ -n "$cd_" ] || cd_=""
    case "$cd_" in ''|/*) : ;; *) cd_="$g/$cd_" ;; esac
  fi
  IFS= read -r h < "$g/HEAD" || [ -n "$h" ] || return 1
  case "$h" in
    "ref: "*)
      ref="${h#ref: }"; h=""
      local d
      for d in "$g" ${cd_:+"$cd_"}; do
        if [ -f "$d/$ref" ]; then
          IFS= read -r h < "$d/$ref" || [ -n "$h" ] || h=""
        elif [ -f "$d/packed-refs" ]; then
          while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in *" $ref") h="${line%% *}"; break ;; esac
          done < "$d/packed-refs"
        fi
        [ -z "$h" ] || break
      done ;;
  esac
  case "$h" in ''|*[!0-9a-f]*) return 1 ;; esac
  [ "${#h}" -eq 40 ] || [ "${#h}" -eq 64 ] || return 1
  HC_HEAD="$h"
}

# HC_INDEXED = index/meta.json .indexed_commit, read with a bash regex (no jq, no python). meta.json is
# written after the data, so a missing or partial one means "no index yet", never a fresh one. Only the first
# 1 KB is read: claudehut-index writes indexed_commit second and keeps the per-file map in index/files.json.
hc_indexed_commit() {
  HC_INDEXED=""
  local m="$PLANE/index/meta.json" s=""
  [ -f "$m" ] || return 1
  IFS= read -r -d '' -n 1024 s < "$m" || :
  [[ $s =~ \"indexed_commit\"[[:space:]]*:[[:space:]]*\"([0-9a-f]{7,64})\" ]] || return 1
  HC_INDEXED="${BASH_REMATCH[1]}"
}

hc_canon() { # resolve . / .. / // without requiring the path to exist (targets are often new files)
  local p="$1" out="" seg rest
  case "$p" in /*) : ;; *) p="$PROJECT_DIR/$p" ;; esac
  rest="$p"
  while [ -n "$rest" ]; do
    seg="${rest%%/*}"
    if [ "$seg" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
    case "$seg" in
      ''|.) : ;;
      ..) out="${out%/*}" ;;
      *) out="$out/$seg" ;;
    esac
  done
  printf '%s' "${out:-/}"
}

# Project-relative path in HC_REL; return 1 when the path is outside the project (scratchpad, other repos).
# macOS: /var → /private/var and /tmp → /private/tmp, so the project root is matched in both spellings.
hc_rel() {
  HC_REL=""
  [ -n "$1" ] || return 1
  local c pd root phys
  c="$(hc_canon "$1")"
  root="$(hc_canon "$PROJECT_DIR")"
  phys="$(cd "$PROJECT_DIR" 2>/dev/null && pwd -P)" || phys=""
  for pd in "$root" "$phys" "/private$root" "${root#/private}"; do
    [ -n "$pd" ] && [ "$pd" != "/" ] || continue
    case "$c" in "$pd"/*) HC_REL="${c#"$pd"/}"; return 0 ;; esac
  done
  return 1
}

hc_in_scope() { # $1 = project-relative path; globs from task.scope (default: production sources only)
  local g globs
  globs="$(jq -r '(.scope // ["src/main/*","*/src/main/*"]) | .[] | strings' <<<"$HC_TASK")" || return 1
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    # shellcheck disable=SC2053  # unquoted on purpose: the scope entry is a glob
    [[ $1 == $g ]] && return 0
  done <<<"$globs"
  return 1
}

hc_once() { # $1 = key; 0 the first time per session, 1 after (sidecar, never the state JSON)
  # The claim is an exclusive create (noclobber), not grep-then-append: Claude Code runs the PreToolUse hooks
  # of parallel tool calls — and of [P] subagents sharing the session — concurrently, and a check-then-append
  # let 2–4 of them pass the check before any appended. Exactly one creator wins; state/<sid>.nudged stays
  # as the human-readable log of what was said.
  [ -n "$HC_SID" ] || return 1
  local k="${1//[!A-Za-z0-9._-]/_}"
  ( set -C; : > "$PLANE/state/$HC_SID.nudged.$k" ) 2>/dev/null || return 1
  printf '%s\n' "$1" >> "$PLANE/state/$HC_SID.nudged" 2>/dev/null || :
  return 0
}

hc_ctx()    { [ -n "$HC_CTX" ] || { HC_EVENT="$1"; HC_CTX="$2"; }; return 0; }
hc_sysmsg() { [ -n "$HC_SYS" ] || HC_SYS="$1"; return 0; }

hc_json_str() { # JSON string literal of $1, pure bash (+ tr for stray control bytes)
  # C locale: bash 3.2 pattern substitution in a UTF-8 locale costs ~60 ms on the 4 KB SessionStart context,
  # ~9 ms byte-wise. Only ASCII is escaped, so UTF-8 bytes pass through intact either way.
  local LC_ALL=C
  local s="$1"
  case "$s" in *[$'\001'-$'\010'$'\013'$'\014'$'\016'-$'\037']*) s="$(printf '%s' "$s" | tr -d '\001-\010\013\014\016-\037')" ;; esac
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}

hc_cut() { # $1 text, $2 max — first $2 characters, never ending inside a UTF-8 sequence, whatever the locale
  # (under LANG=C bash counts bytes, so a plain ${s:0:n} can split a multi-byte character → invalid UTF-8).
  local LC_ALL=C
  local s="${1:0:$2}" c
  c="${s: -1}"
  case "$c" in [$'\x80'-$'\xff']) ;; *) printf '%s' "$s"; return 0 ;; esac
  # drop trailing continuation bytes, then the lead byte that opened the cut sequence
  while [ -n "$s" ]; do
    c="${s: -1}"
    case "$c" in [$'\x80'-$'\xbf']) s="${s%?}" ;; [$'\xc0'-$'\xff']) s="${s%?}"; break ;; *) break ;; esac
  done
  printf '%s' "$s"
}

hc_exit() {
  local rc=$?
  trap - EXIT ERR
  if [ "$rc" -ne 0 ] || [ -n "$HC_FAILED" ]; then
    hc_log "failed rc=$rc sid=${HC_SID:-none}"
    exit 0
  fi
  [ -n "$HC_CTX" ] || [ -n "$HC_SYS" ] || exit 0
  local out="{" sep=""
  if [ -n "$HC_CTX" ]; then
    [ "${#HC_CTX}" -le "$HC_BUDGET" ] || HC_CTX="$(hc_cut "$HC_CTX" "$HC_BUDGET")"
    out="$out\"hookSpecificOutput\":{\"hookEventName\":$(hc_json_str "$HC_EVENT"),\"additionalContext\":$(hc_json_str "$HC_CTX")}"
    sep=","
  fi
  if [ -n "$HC_SYS" ]; then
    [ "${#HC_SYS}" -le 500 ] || HC_SYS="$(hc_cut "$HC_SYS" 500)"
    out="$out$sep\"systemMessage\":$(hc_json_str "$HC_SYS")"
  fi
  printf '%s}\n' "$out"
  exit 0
}
