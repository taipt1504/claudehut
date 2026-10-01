#!/usr/bin/env bash
# PostToolUse hook (matcher: Read|Grep|Glob), SYNC, timeout 2 — cross-service lookup hint (05 §4 row 9, 07 §6, D8).
#
# Microservice planes only. When a Read/Glob/Grep targets a path inside another service repo registered in the hub
# (hub/services.json), or a Grep pattern names another service, it adds ONE fact line pointing at
# `claudehut-index svc <name>` / `links --service <name>` — at most once per (session, agent, service), via
# hc_once. Never counts, never denies, never writes state (K4, K8). Fast path: no plane, mono, or a Read/Glob
# inside the project exit before services.json is read (AC-11: p95 ≤30 ms).

case "$0" in */*) _d="${0%/*}" ;; *) _d="." ;; esac
. "$_d/lib/hook-common.sh" 2>/dev/null || exit 0
HC_LAZY_LANG=1
hc_init
hc_plane_or_exit
[ "$HC_MODE" = microservice ] && [ "$HUB" != "$PLANE" ] || exit 0

# Fields by bash regex: the leftmost `"key": "` is the top-level/tool_input one (strings inside tool_response are
# escaped, so they cannot match). \\ \" \/ are unescaped in bash (a Grep regex is full of them: `foo\(`); only a
# value carrying another escape (\n \t \uXXXX …) falls back to one jq read of the three fields.
hx_esc=false
hx() { # $1 key → HX (empty when absent)
  HX=""
  local re="\"$1\"[[:space:]]*:[[:space:]]*\"(([^\"\\\\]|\\\\.)*)\"" t bb='\\' bq='\"' bs='\/'
  [[ $HC_IN =~ $re ]] || return 0
  HX="${BASH_REMATCH[1]}"
  case "$HX" in *\\*)
    t="${HX//"$bb"/}"; t="${t//"$bq"/}"; t="${t//"$bs"/}"
    case "$t" in *\\*) hx_esc=true; return 0 ;; esac
    t="${HX//"$bb"/$'\x01'}"; t="${t//"$bq"/\"}"; t="${t//"$bs"//}"; HX="${t//$'\x01'/\\}" ;;
  esac
  return 0
}
hx tool_name; tool="$HX"
case "$tool" in Read) hx file_path; target="$HX"; pattern="" ;;
  Grep|Glob) hx path; target="$HX"; hx pattern; pattern="$HX" ;;
  *) exit 0 ;;
esac
if $hx_esc; then
  IFS=$'\x1f' read -r tool target pattern <<<"$(jq -r '[(.tool_name // ""), (.tool_input.file_path // .tool_input.path // ""),
    (.tool_input.pattern // "")] | map(tostring) | join("\u001f")' <<<"$HC_IN")" || exit 0
fi
# A Glob pattern can carry the directory itself (/ws/b-ms/**/*.java).
if [ "$tool" = Glob ] && [ -z "$target" ]; then case "$pattern" in /*|../*) target="${pattern%%[*?\{\[]*}" ;; esac; fi
[ "$tool" = Grep ] || pattern=""
# Everything below is bash only (no fork): the one jq of this hook is hc_plane_or_exit's topology read.
cv() { # hc_canon without the $(…) subshell: result in CV
  local p="$1" seg rest; CV=""
  case "$p" in /*) : ;; *) p="$PROJECT_DIR/$p" ;; esac
  rest="$p"
  while [ -n "$rest" ]; do
    seg="${rest%%/*}"
    if [ "$seg" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
    case "$seg" in ''|.) : ;; ..) CV="${CV%/*}" ;; *) CV="$CV/$seg" ;; esac
  done
  CV="${CV:-/}"
}
cv "$PROJECT_DIR"; proj="$CV"
if [ -n "$target" ]; then
  cv "$target"; target="$CV"
  # This repo (either spelling of macOS /private) → only a Grep pattern can still name another service.
  case "$target" in "$proj"|"$proj"/*|"/private$proj"|"/private$proj"/*|"${proj#/private}"|"${proj#/private}"/*) target="" ;; esac
fi
[ -n "$target" ] || [ -n "$pattern" ] || exit 0

hub="$HUB"; case "$hub" in /*) : ;; *) hub="$PROJECT_DIR/$hub" ;; esac
cv "$hub"; hub="$CV"
sj="$hub/.claude/claudehut/hub/services.json"
[ -f "$sj" ] || exit 0
# services.json: {"<svc>": {path (relative to the hub root, or absolute), remote, indexed_commit, …}} — flat entries,
# so each one is `"<svc>": { … }` without a nested brace. A target under a service's repo wins, else the service a Grep
# pattern names first as a whole word (its key or its repo dir). This repo is never "another service".
IFS= read -r -d '' sjs < "$sj" || :
# A bare Grep pattern: no word of it quoted as a key in services.json → no service named, skip the entry loop.
if [ -z "$target" ]; then
  hit=false
  for tk in ${pattern//[^A-Za-z0-9._-]/ }; do
    for t in "$tk" ${tk//./ }; do [[ $sjs == *"\"$t\""* || $sjs == *"/$t\""* || $sjs == *"/$t/\""* ]] && { hit=true; break 2; }; done
  done
  $hit || exit 0
fi
t2=""; case "$target" in '') : ;; /private/*) t2="${target#/private}" ;; *) t2="/private$target" ;; esac
svc=""; me="${HC_SVC:-${proj##*/}}"
# One in-memory split on `}` (flat entries): no regex rescan of the rest of the file per entry, and no here-string
# (bash writes it to a temp file) — AC-11.
split_ents() { local IFS='}'; set -f; ents=($sjs); set +f; }
split_ents
kre='"([A-Za-z0-9._-]+)"[[:space:]]*:[[:space:]]*\{(.*)$'
pre='"path"[[:space:]]*:[[:space:]]*"([^"]*)"'
ws=(); ks=(); alt=""
for e in "${ents[@]}"; do
  [[ $e =~ $kre ]] || continue
  n="${BASH_REMATCH[1]}"; body="${BASH_REMATCH[2]}"
  [ "$n" != "$me" ] && [ "$n" != "${proj##*/}" ] || continue
  d=""; [[ $body =~ $pre ]] && d="${BASH_REMATCH[1]%/}"
  if [ -n "$target" ] && [ -n "$d" ]; then
    dd="$d"; case "$dd" in /*) : ;; *) dd="$hub/$dd" ;; esac
    cv "$dd"; dd="$CV"
    if [ "$dd" != "$proj" ]; then
      case "$target" in "$dd"|"$dd"/*) svc="$n"; break ;; esac
      case "$t2" in "$dd"|"$dd"/*) svc="$n"; break ;; esac
    fi
  fi
  # The key, or the repo dir it was registered from (auth-ms for auth-service): one alternation, matched once.
  for w in "$n" ${d:+"${d##*/}"}; do
    case "$w" in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    ws+=("$w"); ks+=("$n"); alt="$alt${alt:+|}${w//./[.]}"
  done
done
# A pattern naming several services hints the one it names first.
if [ -z "$svc" ] && [ -n "$pattern" ] && [ -n "$alt" ]; then
  wre="(^|[^A-Za-z0-9_-])($alt)(\$|[^A-Za-z0-9_-])"
  if [[ $pattern =~ $wre ]]; then
    w="${BASH_REMATCH[2]}"
    for i in "${!ws[@]}"; do [ "${ws[$i]}" = "$w" ] && { svc="${ks[$i]}"; break; }; done
  fi
fi
[ -n "$svc" ] && hc_safe_id "$svc" || exit 0
hx agent_id; a="${HX:-main}"; hc_safe_id "$a" || a=agent
hc_once "hint.$a.$svc" || exit 0

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$_d/.." 2>/dev/null && pwd)}"
cli="$PLUGIN_ROOT/bin/claudehut-index"
hc_hub_lang
if [ "$HC_LANG" = vi ]; then
  hc_ctx PostToolUse "ClaudeHut hub: $svc là service khác trong hub. \`$cli svc $svc\` (endpoint, topic, client, DB) hoặc \`links --service $svc\` thường đủ, không cần đọc repo đó."
else
  hc_ctx PostToolUse "ClaudeHut hub: $svc is another service in the hub. \`$cli svc $svc\` (endpoints, topics, clients, DB) or \`links --service $svc\` usually answers this without reading its repo."
fi
exit 0
