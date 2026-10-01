#!/usr/bin/env bash
# review-pack.sh — deterministic review lane selection + one SHA-pinned pack per lane (08-review.md §3–§4,
# ADR-V1/V2/V8). The script decides what must be right every time (base, file set, signals, pack bounds);
# the main thread decides judgment (accept/override lanes, one line of reason per change). Advisory: it
# never blocks a dispatch, always exits 0 and always prints ONE JSON line on stdout.
#
# Usage:
#   review-pack.sh [--json] [--round N] [--prev <review.md>] [--carry-lanes a,b] [--base <tree-ish>]
#                  [--head <commit>] [--route light|full] [--task <id>] [--session <sid>] [--repo <dir>]
#                  [--only a,b] [--out <dir>] [--paths <pathspec>...]
#   --json          accepted for the shared contract; the output is always one JSON line
#   --round N       1 (default) · 2 = carry ∪ lanes triggered by the fix diff (+ reviewer, + test on full when the
#                   fix touches source) · ≥3 = capped: no lanes, the caller runs `set-review capped`
#   --prev FILE     round 2: carry every lane whose row still shows ✗ or OUTSTANDING in FILE (rows of its `## Lanes`
#                   section, else of any table, whose cell names a lane or agent). --carry-lanes adds to it.
#   --base X        diff base. Default: active task → task.base[<repo key>] minus pre_dirty[<repo key>]; round 2 →
#                   head_tree of lanes.r1.json in the pack dir; otherwise merge-base @{u} → origin/HEAD →
#                   origin/main → HEAD~1 → empty tree
#   --head C        review the committed tree of C instead of the worktree (read-only: no snapshot, no
#                   untracked files; used by evals/review-replay.sh against repos that must not be written)
#   --only a,b      narrow to these lanes (aliases perf→db, observability→contract, tests→test); reviewer stays
#   --task/--session  which task.json to read (default: $CLAUDEHUT_SESSION_ID's active_task in the plane)
#   --out DIR       pack dir; default <plane>/tasks/<id>/review/ with a task, else a fresh temp dir
#
# Output (also written to <out>/lanes.r<N>.json and <out>/lanes.json):
#   {round, route, task, base, base_sha, head_sha, head_tree, reviewed_tree, out_dir, files, diff_lines,
#    lanes:[{lane,name,agent,reasons[],depth,pack,lines}], skipped:[{lane,name,reason,why}],
#    partial:[{lane,uncovered:[files]}] (a selected lane whose pack omits some source files of the diff), uncovered[],
#    hints:[{lane,reason:"enf:<item>"}], excluded[] (≤40), excluded_count, large, ask_user, ask_reason, capped,
#    degraded, degraded_reason}
# Enforcement items (task.enforcement_set) never select a lane: they route into the pack of the lane their prefix
# names, show up as `hints`, and go to the reviewer pack when that lane is not run. depth=deep for a selected lane
# that carries ≥1 enforcement item, or security touching auth.
# `name`/`why`/`reviewed_tree` duplicate `lane`/`reason`/`head_tree` so both spellings of the contract parse.
#
# Snapshot (worktree mode): a TEMP index — read-tree HEAD → add -A -- FILES → write-tree = reviewed_tree. The
# repo's own index and worktree are never touched; right after, `git diff <reviewed_tree>` is empty for tracked non-pre_dirty
# paths (untracked FILES show as D only because the real index lacks them). Every hunk
# in every pack comes from `git diff BASE reviewed_tree`, so a pack is pinned even if the worktree moves on.
set -uo pipefail

EMPTY_TREE=4b825dc642cb6eb9a060e54bf8d69288fbee4904
MAX_PACK_LINES=1500
LARGE_LINES=1500
LARGE_FILES=30
export GIT_OPTIONAL_LOCKS=0 LC_ALL=C
T="$(printf '\t')"

# ---- signal table (08 §3.2) — one rule per line: lane kind label ERE -------------------------------------
# kind: path = ERE on the repo-relative path · hunk = ERE on a +/- content line (never a header, never
# context) · mainhunk = hunk rule outside test sources (a .block() in a test is not a blocking call on a
# request path) · secret = case-insensitive hunk rule, only in application*.yml|yaml|properties · enf = ERE on an
# enforcement item (".claude/rules/" and ".md" stripped) — routing + hint only, never a lane selector. The secret rule is anchored at the key and skips a
# ${VAR} / ${VAR:default} value. Mono/Flux alone is deliberately NOT a signal (E1);
# @*Mapping is contract, never security (08 §3.2 question 4, decided 2026-09-29). Annotation rules also match
# the fully-qualified spelling (@org.springframework…GetMapping).
rules() {
cat <<'RULES'
security path security/ (^|/)security/
security path auth/ (^|/)auth/
security path SecurityConfig SecurityConfig[^/]*$
security path Filter.java Filter\.java$
security hunk @PreAuthorize @([[:alnum:]_]+\.)*PreAuthorize
security hunk @Secured @([[:alnum:]_]+\.)*Secured
security hunk SecurityFilterChain SecurityFilterChain
security hunk permitAll permitAll
security hunk JwtDecoder JwtDecoder
security hunk PasswordEncoder PasswordEncoder
security hunk activateDefaultTyping (activate|enable)DefaultTyping
security hunk ObjectInputStream ObjectInputStream
security secret secret [a-z0-9_.-]*(password|passwd|secret|api[-_]?key|private[-_]?key|credentials?|token)[a-z0-9_.-]*["']?[[:space:]]*[:=][[:space:]]*["']?[^[:space:]"'$}{]
security enf security/* ^security/
db path db/migration/ (^|/)db/migration/
db path .sql \.sql$
db path Repository Repository[^/]*$
db hunk @Entity @([[:alnum:]_]+\.)*Entity
db hunk @Table @([[:alnum:]_]+\.)*Table
db hunk @Query @([[:alnum:]_]+\.)*Query
db hunk DatabaseClient DatabaseClient
db hunk JdbcTemplate JdbcTemplate
db hunk @Transactional @([[:alnum:]_]+\.)*Transactional
db hunk TransactionalOperator TransactionalOperator
db hunk @Cacheable @([[:alnum:]_]+\.)*Cacheable
db mainhunk .block( \.block\(
db mainhunk Thread.sleep Thread\.sleep
db enf performance/* ^performance/
db enf framework/jpa|r2dbc|flyway|migration|lombok-jpa ^framework/(jpa|r2dbc|flyway|migration|lombok-jpa)
contract path .avsc \.avsc$
contract path .proto \.proto$
contract path openapi (^|/)openapi[^/]*$
contract path asyncapi (^|/)asyncapi[^/]*$
contract path kafka-config (^|/)src/main/(.*/)?(kafka/(.*/)?[^/]*|[^/]*(Consumer|Producer|Kafka))Config[^/]*\.java$
contract hunk @KafkaListener @([[:alnum:]_]+\.)*KafkaListener
contract hunk KafkaTemplate KafkaTemplate
contract hunk @RabbitListener @([[:alnum:]_]+\.)*RabbitListener
contract hunk @*Mapping @([[:alnum:]_]+\.)*(Get|Post|Put|Delete|Patch|Request)Mapping
contract hunk WebClient WebClient
contract hunk RestClient RestClient
contract hunk @FeignClient @([[:alnum:]_]+\.)*FeignClient
contract hunk @Scheduled @([[:alnum:]_]+\.)*Scheduled
contract hunk MeterRegistry MeterRegistry
contract hunk @Timed @([[:alnum:]_]+\.)*Timed
contract hunk @Observed @([[:alnum:]_]+\.)*Observed
contract enf framework/contract* ^framework/contract
contract enf framework/kafka* ^framework/kafka
contract enf observability/* ^observability/
contract enf coding/logging-mdc ^coding/logging-mdc
RULES
}

agent_of() {
  case "$1" in
    reviewer) echo claudehut-reviewer ;; test) echo claudehut-test-runner ;;
    security) echo claudehut-security-auditor ;; db) echo claudehut-db-reviewer ;;
    contract) echo claudehut-contract-reviewer ;;
  esac
}
lane_of() { # lane name, agent name or alias → lane ("" when none)
  local x; x="$(printf '%s' "$1" | tr 'A-Z' 'a-z' | sed -e 's/[`*[:space:]]//g' -e 's/^claudehut[:-]//' -e 's/^claudehut-//')"
  case "$x" in
    reviewer|general-reviewer) echo reviewer ;; test|tests|test-runner) echo test ;;
    security|security-auditor) echo security ;; db|db-reviewer|perf|perf-reviewer|performance) echo db ;;
    contract|contract-reviewer|observability|observability-reviewer) echo contract ;;
  esac
}

# ---- degraded output without jq (printf, never fails) --------------------------------------------------
json_str() { printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"; }
fallback() { # $1 reason ; ONLY_LANES may name lanes
  local lanes l seen=" reviewer " out
  lanes="{\"lane\":\"reviewer\",\"name\":\"reviewer\",\"agent\":\"claudehut-reviewer\",\"reasons\":[\"always\"],\"depth\":\"standard\",\"pack\":\"\",\"lines\":0}"
  for l in $(printf '%s' "${ONLY_RAW:-}" | tr ',' ' '); do
    l="$(lane_of "$l")"; [ -n "$l" ] || continue
    case "$seen" in *" $l "*) continue ;; esac; seen="$seen$l "
    lanes="$lanes,{\"lane\":\"$l\",\"name\":\"$l\",\"agent\":\"$(agent_of "$l")\",\"reasons\":[\"only:$l\"],\"depth\":\"standard\",\"pack\":\"\",\"lines\":0}"
  done
  out="{\"round\":${ROUND:-1},\"lanes\":[$lanes],\"skipped\":[],\"uncovered\":[],\"large\":false,\"ask_user\":false,\"ask_reason\":\"\",\"capped\":false,\"degraded\":true,\"degraded_reason\":$(json_str "$1")}"
  printf '%s\n' "$out"
  exit 0
}

# ---- args ---------------------------------------------------------------------------------------------
ROUND=1; PREV=""; CARRY_RAW=""; BASE_ARG=""; HEAD_ARG=""; ROUTE_ARG=""; TASK_ARG=""; SID="${CLAUDEHUT_SESSION_ID:-}"
REPO_ARG=""; ONLY_RAW=""; OUT_ARG=""; PATHS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --json) shift ;;
    --round) ROUND="${2:-1}"; shift 2 ;;
    --prev) PREV="${2:-}"; shift 2 ;;
    --carry-lanes) CARRY_RAW="${2:-}"; shift 2 ;;
    --base) BASE_ARG="${2:-}"; shift 2 ;;
    --head) HEAD_ARG="${2:-}"; shift 2 ;;
    --route) ROUTE_ARG="${2:-}"; shift 2 ;;
    --task) TASK_ARG="${2:-}"; shift 2 ;;
    --session) SID="${2:-}"; shift 2 ;;
    --repo) REPO_ARG="${2:-}"; shift 2 ;;
    --only) ONLY_RAW="${2:-}"; shift 2 ;;
    --out) OUT_ARG="${2:-}"; shift 2 ;;
    --paths) shift; while [ $# -gt 0 ]; do case "$1" in --*) break ;; esac; PATHS+=("$1"); shift; done ;;
    *) shift ;;
  esac
done
case "$ROUND" in ''|*[!0-9]*) ROUND=1 ;; esac
[ "$ROUND" -ge 1 ] || ROUND=1

command -v jq >/dev/null 2>&1 || fallback "jq not found"
command -v git >/dev/null 2>&1 || fallback "git not found"
REPO="$(git -C "${REPO_ARG:-$PWD}" rev-parse --show-toplevel 2>/dev/null)" || fallback "not a git repository"
g() { git -C "$REPO" -c core.quotePath=false "$@"; }

W="$(mktemp -d "${TMPDIR:-/tmp}/review-pack.XXXXXX")" || fallback "mktemp failed"
trap 'rm -rf "$W"' EXIT
DEGRADED=false; DEGR=""
degrade() { DEGRADED=true; DEGR="${DEGR:+$DEGR; }$1"; }

# ---- task / plane -------------------------------------------------------------------------------------
PROJECT="${CLAUDE_PROJECT_DIR:-$REPO}"
PLANE="$PROJECT/.claude/claudehut"
TASK_ID="$TASK_ARG"
if [ -z "$TASK_ID" ] && [ -n "$SID" ] && [ -f "$PLANE/state/$SID.json" ]; then
  TASK_ID="$(jq -r 'if type=="object" and .schema==2 then (.active_task // empty) else empty end' "$PLANE/state/$SID.json" 2>/dev/null || true)"
fi
TASK='{}'
if [ -n "$TASK_ID" ]; then
  if [ -f "$PLANE/tasks/$TASK_ID/task.json" ] && jq -e 'type=="object" and .schema==2' "$PLANE/tasks/$TASK_ID/task.json" >/dev/null 2>&1; then
    TASK="$(jq -c . "$PLANE/tasks/$TASK_ID/task.json")"
  else
    degrade "task $TASK_ID has no schema-2 task.json"; TASK_ID=""
  fi
fi
# repo key as claudehut-state writes it: path relative to the project, '.' for the project itself
pabs="$(cd "$PROJECT" 2>/dev/null && pwd -P || printf '%s' "$PROJECT")"; rabs="$(cd "$REPO" && pwd -P)"
case "$rabs" in "$pabs") RKEY="." ;; "$pabs"/*) RKEY="${rabs#"$pabs"/}" ;; *) RKEY="$rabs" ;; esac

ROUTE="$ROUTE_ARG"
[ -n "$ROUTE" ] || ROUTE="$(jq -r '.route // empty' <<<"$TASK")"
case "$ROUTE" in full) : ;; light) : ;; *) ROUTE=light ;; esac   # direct / out-of-workflow review = light

if [ -n "$OUT_ARG" ]; then OUT="$OUT_ARG"
elif [ -n "$TASK_ID" ]; then OUT="$PLANE/tasks/$TASK_ID/review"
else OUT="$(mktemp -d "${TMPDIR:-/tmp}/claudehut-review.XXXXXX")"; fi
mkdir -p "$OUT" 2>/dev/null || fallback "cannot create $OUT"
# packs quote hunks verbatim (a security pack may carry a literal secret line): never let git pick them up
[ -z "$OUT_ARG" ] && [ -n "$TASK_ID" ] && [ ! -f "$OUT/.gitignore" ] && printf '*\n' > "$OUT/.gitignore" 2>/dev/null

# ---- round ≥3: capped ---------------------------------------------------------------------------------
if [ "$ROUND" -ge 3 ]; then
  jq -nc --argjson r "$ROUND" --arg route "$ROUTE" --arg task "$TASK_ID" --arg out "$OUT" \
    '{round:$r, route:$route, task:(if $task=="" then null else $task end), out_dir:$out, lanes:[],
      skipped:[{lane:"all",name:"all",reason:"round cap (max 2): run set-review capped",why:"round cap (max 2): run set-review capped"}],
      uncovered:[], large:false, ask_user:false, ask_reason:"", capped:true, degraded:false, degraded_reason:""}' \
    | tee "$OUT/lanes.r$ROUND.json" "$OUT/lanes.json"
  exit 0
fi

# ---- BASE ---------------------------------------------------------------------------------------------
BASE="$BASE_ARG"; BASE_SRC="--base"
if [ -z "$BASE" ] && [ "$ROUND" -ge 2 ] && [ -f "$OUT/lanes.r$((ROUND-1)).json" ]; then
  BASE="$(jq -r '.head_tree // empty' "$OUT/lanes.r$((ROUND-1)).json" 2>/dev/null)"; BASE_SRC="round $((ROUND-1)) head_tree"
fi
[ -n "$BASE" ] || [ "$ROUND" -lt 2 ] || degrade "round $ROUND without --base or lanes.r$((ROUND-1)).json: diffing from the round-1 base"
if [ -z "$BASE" ] && [ -n "$TASK_ID" ]; then
  BASE="$(jq -r --arg k "$RKEY" '.base[$k] // empty' <<<"$TASK")"; BASE_SRC="task.base[$RKEY]"
  [ -n "$BASE" ] || degrade "task.base has no entry for repo key $RKEY"
fi
if [ -z "$BASE" ]; then
  for ref in '@{u}' origin/HEAD origin/main; do
    BASE="$(g merge-base HEAD "$ref" 2>/dev/null)" && [ -n "$BASE" ] && { BASE_SRC="merge-base $ref"; break; }
    BASE=""
  done
fi
[ -n "$BASE" ] || { BASE="$(g rev-parse -q --verify 'HEAD~1^{commit}' 2>/dev/null)" && BASE_SRC="HEAD~1"; }
[ -n "$BASE" ] || { BASE="$EMPTY_TREE"; BASE_SRC="empty tree"; }
BASE_SHA="$(g rev-parse -q --verify "$BASE^{commit}" 2>/dev/null || g rev-parse -q --verify "$BASE^{tree}" 2>/dev/null)"
[ -n "$BASE_SHA" ] || { degrade "base $BASE does not resolve; using HEAD~1"; BASE_SHA="$(g rev-parse -q --verify 'HEAD~1' 2>/dev/null || echo "$EMPTY_TREE")"; }

# ---- FILES --------------------------------------------------------------------------------------------
excluded() { # 0 = drop the path (08 §4 FILES)
  case "$1" in
    .claude/*|*/.claude/*|docs/*|build/*|*/build/*|target/*|*/target/*) return 0 ;;
    */generated/*|generated/*|*.generated.*) return 0 ;;
    *.lock|*.lockfile|package-lock.json|*/package-lock.json|pnpm-lock.yaml|*/pnpm-lock.yaml|yarn.lock|*/yarn.lock) return 0 ;;
  esac
  case "$1" in src/*|*/src/*) return 1 ;; */docs/*) return 0 ;; esac
  return 1
}
untracked_ok() { # untracked files enter only through this allowlist (E2)
  case "$1" in src/*|*/src/*|*.gradle|*.gradle.kts|*/gradle.properties|gradle.properties|pom.xml|*/pom.xml|*.avsc|*.proto) return 0 ;; esac
  case "${1##*/}" in openapi*) return 0 ;; esac
  return 1
}
PRE_DIRTY="$W/pre_dirty"; : > "$PRE_DIRTY"
if [ -n "$TASK_ID" ]; then   # every round of a task: files dirty before the task started are not its change
  jq -r --arg k "$RKEY" '.pre_dirty[$k][]? // empty' <<<"$TASK" > "$PRE_DIRTY" 2>/dev/null || true
fi
RAW="$W/raw"; : > "$RAW"
if [ -n "$HEAD_ARG" ]; then
  HEAD_SHA="$(g rev-parse -q --verify "$HEAD_ARG^{commit}" 2>/dev/null)" || fallback "--head $HEAD_ARG does not resolve"
  g diff --no-renames --name-only "$BASE_SHA" "$HEAD_SHA" -- ${PATHS[@]+"${PATHS[@]}"} >> "$RAW" 2>/dev/null
else
  HEAD_SHA="$(g rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null || echo "")"
  g diff --no-renames --name-only "$BASE_SHA" -- ${PATHS[@]+"${PATHS[@]}"} >> "$RAW" 2>/dev/null
  g ls-files --others --exclude-standard -- ${PATHS[@]+"${PATHS[@]}"} 2>/dev/null | while IFS= read -r f; do
    untracked_ok "$f" && printf '%s\n' "$f"
  done >> "$RAW"
fi
FILES="$W/files"; EXCL="$W/excl"; : > "$EXCL"
sort -u "$RAW" | while IFS= read -r f; do
  [ -n "$f" ] || continue
  excluded "$f" && { printf '%s\n' "$f" >> "$EXCL"; continue; }
  grep -qxF -- "$f" "$PRE_DIRTY" 2>/dev/null && continue
  printf '%s\n' "$f"
done > "$FILES"
NFILES="$(grep -c . "$FILES" || true)"

# ---- snapshot -----------------------------------------------------------------------------------------
if [ -n "$HEAD_ARG" ]; then
  TREE="$(g rev-parse "$HEAD_SHA^{tree}")"
else
  TREE=""
  IDX="$W/index"
  if [ -n "$HEAD_SHA" ]; then GIT_INDEX_FILE="$IDX" g read-tree HEAD 2>/dev/null || true
  else GIT_INDEX_FILE="$IDX" g read-tree --empty 2>/dev/null || true; fi
  # a deleted path is staged only when the temp index knows it; one missing pathspec would fail the whole add
  while IFS= read -r f; do
    if [ -e "$REPO/$f" ] || [ -L "$REPO/$f" ] || GIT_INDEX_FILE="$IDX" g ls-files --error-unmatch -- ":(literal)$f" >/dev/null 2>&1; then
      printf ':(literal)%s\0' "$f"
    fi
  done < "$FILES" > "$W/pathspec"
  if [ -s "$W/pathspec" ]; then
    GIT_INDEX_FILE="$IDX" g add -A --pathspec-from-file="$W/pathspec" --pathspec-file-nul >/dev/null 2>"$W/add.err" \
      && TREE="$(GIT_INDEX_FILE="$IDX" g write-tree 2>/dev/null)"
  else
    TREE="$(GIT_INDEX_FILE="$IDX" g write-tree 2>/dev/null)"
  fi
  if [ -z "$TREE" ]; then
    degrade "snapshot failed ($(head -c 160 "$W/add.err" 2>/dev/null | tr '\n' ' ')): reviewed_tree=HEAD"
    TREE="$(g rev-parse -q --verify 'HEAD^{tree}' 2>/dev/null || echo "$EMPTY_TREE")"
  fi
fi

# FILES = paths that really differ between BASE and the reviewed tree: an untracked file identical to BASE (round 2:
# the round-1 reviewed_tree already holds it) is no change and must not re-trigger a lane (ADR-V8)
g diff --no-renames --name-only "$BASE_SHA" "$TREE" -- 2>/dev/null | sort -u > "$W/changed"
sort -u "$FILES" | comm -12 - "$W/changed" > "$W/files2"; mv "$W/files2" "$FILES"
NFILES="$(grep -c . "$FILES" || true)"

# ---- hunks: path<TAB>content, +/- lines only, headers skipped ----------------------------------------
HUNKS="$W/hunks"; : > "$HUNKS"
if [ -s "$FILES" ]; then
  tr '\n' '\0' < "$FILES" | xargs -0 git -C "$REPO" -c core.quotePath=false diff --no-renames --no-color -U0 "$BASE_SHA" "$TREE" -- 2>/dev/null \
  | awk -v T="$T" '
      /^diff --git / { f=""; h=0; next }
      !h && /^\+\+\+ / { p=substr($0,5); sub(/\t$/,"",p); if (p!="/dev/null") f=substr(p,3); next }
      !h && /^--- / { p=substr($0,5); sub(/\t$/,"",p); if (p!="/dev/null" && f=="") f=substr(p,3); next }
      /^@@/ { h=1; next }
      h && /^[+-]/ && f!="" { print f T substr($0,2) }' > "$HUNKS"
fi
# full per-file diffs for the packs: ONE git call, split into $W/fd/<n>;
# $W/fd.idx: path<TAB>n<TAB>lines<TAB>bin|txt|del<TAB>removed lines (del = deletion-only: listed by name, never inlined)
mkdir -p "$W/fd"; : > "$W/fd.idx"
if [ -s "$FILES" ]; then
  tr '\n' '\0' < "$FILES" | xargs -0 git -C "$REPO" -c core.quotePath=false diff --no-renames --no-color "$BASE_SHA" "$TREE" -- 2>/dev/null \
  | awk -v T="$T" -v D="$W/fd" -v IDX="$W/fd.idx" '
      function flush() { if (n > 0 && f != "") { out = D "/" n; printf "%s", buf > out; close(out)
                           print f T n T lines T (bin ? "bin" : (plus ? "txt" : "del")) T minus > IDX } }
      /^diff --git / { flush(); n++; buf=""; f=""; h=0; lines=0; bin=0; plus=0; minus=0 }
      !h && /^\+\+\+ / { p=substr($0,5); sub(/\t$/,"",p); if (p!="/dev/null") f=substr(p,3) }
      !h && /^--- / { p=substr($0,5); sub(/\t$/,"",p); if (p!="/dev/null" && f=="") f=substr(p,3) }
      !h && /^Binary files / { bin=1; if (f=="") { p=$0; sub(/^Binary files a\//,"",p); sub(/ and .*/,"",p); f=p } }
      h && /^\+/ { plus=1 }
      h && /^-/ { minus++ }
      /^@@/ { h=1 }
      { buf = buf $0 "\n"; lines++ }
      END { flush() }'
fi
DIFF_LINES=0
[ -s "$FILES" ] && DIFF_LINES="$(tr '\n' '\0' < "$FILES" | xargs -0 git -C "$REPO" -c core.quotePath=false diff --no-renames --numstat "$BASE_SHA" "$TREE" -- 2>/dev/null \
  | awk '$1!="-"{s+=$1+$2} END{print s+0}')"

# ---- signals: lane<TAB>reason<TAB>file ----------------------------------------------------------------
SIG="$W/sig"; : > "$SIG"
ENF="$W/enf"; jq -r '.enforcement_set[]? | tostring' <<<"$TASK" > "$ENF" 2>/dev/null || : > "$ENF"
ENF_ROUTED="$W/enf_routed"; : > "$ENF_ROUTED"   # lane<TAB>item
while read -r lane kind label re; do
  [ -n "$lane" ] || continue
  case "$kind" in
    path) grep -E -- "$re" "$FILES" 2>/dev/null | while IFS= read -r f; do printf '%s\tpath:%s %s\t%s\n' "$lane" "$label" "$f" "$f"; done ;;
    hunk) grep -E -- "^[^$T]*$T.*($re)" "$HUNKS" 2>/dev/null | cut -f1 | sort -u | while IFS= read -r f; do
            printf '%s\thunk:%s %s\t%s\n' "$lane" "$label" "${f##*/}" "$f"; done ;;
    mainhunk) grep -E -- "^[^$T]*$T.*($re)" "$HUNKS" 2>/dev/null | cut -f1 | sort -u \
            | grep -vE '(^|/)src/test/|(Test|Tests|IT)\.(java|kt)$' | while IFS= read -r f; do
            printf '%s\thunk:%s %s\t%s\n' "$lane" "$label" "${f##*/}" "$f"; done ;;
    secret) grep -iE -- "^([^$T]*/)?application[^/$T]*\.(yml|yaml|properties)$T[[:space:]]*($re)" "$HUNKS" 2>/dev/null | cut -f1 | sort -u \
            | while IFS= read -r f; do printf '%s\thunk:%s %s\t%s\n' "$lane" "$label" "${f##*/}" "$f"; done ;;
    enf) while IFS= read -r item; do
           n="$(printf '%s' "$item" | sed -e 's#^\.claude/rules/##' -e 's#\.md$##')"
           if printf '%s\n' "$n" | grep -qE -- "$re"; then
             # enforcement routes items into packs and hints a lane, but never selects one: lanes come from
             # path/hunk signals only (08 §3.2, M4 fan-out finding) — a task-wide rule set says nothing about this diff
             printf '%s\t%s\n' "$lane" "$item" >> "$ENF_ROUTED"
           fi
         done < "$ENF" ;;
  esac >> "$SIG"
done < <(rules)
sort -u -o "$SIG" "$SIG"; sort -u -o "$ENF_ROUTED" "$ENF_ROUTED"

# ---- source-ness and uncovered ------------------------------------------------------------------------
is_source() { case "$1" in *.md|*.txt|*.adoc|*.rst) return 1 ;; esac; return 0; }
covered_type() {
  case "$1" in
    *.java|*.kt|*.kts|*.sql|*.yml|*.yaml|*.properties|*.avsc|*.proto|*.json|*.graphql|*.graphqls|*.xsd) return 0 ;;
    *.gradle|pom.xml|*/pom.xml|*.toml|*/gradlew|gradlew|*/mvnw|mvnw) return 0 ;;
  esac
  return 1
}
SRC_CHANGED=false
while IFS= read -r f; do is_source "$f" && { SRC_CHANGED=true; break; }; done < "$FILES"
UNCOV="$W/uncov"; : > "$UNCOV"
while IFS= read -r f; do covered_type "$f" || printf '%s\n' "$f" >> "$UNCOV"; done < "$FILES"

# ---- lane decision ------------------------------------------------------------------------------------
DEC="$W/dec"; : > "$DEC"    # lane<TAB>reason   (selected)
SKP="$W/skp"; : > "$SKP"    # lane<TAB>reason   (skipped)
printf 'reviewer\talways (every route)\n' >> "$DEC"
if [ "$ROUTE" = full ]; then
  if $SRC_CHANGED; then printf 'test\troute:full source changed\n' >> "$DEC"
  else printf 'test\troute full but the diff touches no source/build file\n' >> "$SKP"; fi
else
  printf 'test\troute:light — test folded into reviewer\n' >> "$SKP"
fi
for lane in security db contract; do
  if grep -q "^$lane$T" "$SIG"; then grep "^$lane$T" "$SIG" | cut -f1,2 >> "$DEC"
  else
    h="$(grep -c "^$lane$T" "$ENF_ROUTED" || true)"
    if [ "${h:-0}" -gt 0 ]; then printf '%s\tno signal in paths or +/- hunks (enforcement hint: %s item(s), in the reviewer pack)\n' "$lane" "$h" >> "$SKP"
    else printf '%s\tno signal in paths or +/- hunks\n' "$lane" >> "$SKP"; fi
  fi
done
# round 2: carry lanes (still ✗) are selected even without a signal on the fix diff
CARRY="$W/carry"; : > "$CARRY"
for l in $(printf '%s' "$CARRY_RAW" | tr ',' ' '); do l="$(lane_of "$l")"; [ -n "$l" ] && printf '%s\n' "$l" >> "$CARRY"; done
if [ -n "$PREV" ] && [ -f "$PREV" ]; then
  # the `## Lanes` section when the file has one (08 §6.2), else every table row of the file
  if grep -qE '^## +Lanes' "$PREV"; then awk '/^## +Lanes/{f=1;next} /^## /{f=0} f' "$PREV"; else cat "$PREV"; fi \
  | grep '^|' | grep -E '✗|OUTSTANDING' | tr '|' '\n' | while IFS= read -r cell; do
      l="$(lane_of "$cell")"; [ -n "$l" ] && printf '%s\n' "$l"
    done >> "$CARRY"
fi
sort -u -o "$CARRY" "$CARRY"
if [ "$ROUND" -ge 2 ]; then
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    [ "$l" = test ] && [ "$ROUTE" != full ] && continue
    printf '%s\tcarry: still ✗ in round %s\n' "$l" "$((ROUND-1))" >> "$DEC"
  done < "$CARRY"
fi
# --only narrows (reviewer always stays)
if [ -n "$ONLY_RAW" ]; then
  ONLY=" reviewer "; for l in $(printf '%s' "$ONLY_RAW" | tr ',' ' '); do l="$(lane_of "$l")"; [ -n "$l" ] && ONLY="$ONLY$l "; done
  : > "$W/dec2"
  while IFS="$T" read -r l r; do
    case "$ONLY" in *" $l "*) printf '%s\t%s\n' "$l" "$r" >> "$W/dec2" ;; *) printf '%s\t--only %s\n' "$l" "$ONLY_RAW" >> "$SKP" ;; esac
  done < "$DEC"
  for l in $ONLY; do grep -q "^$l$T" "$W/dec2" || printf '%s\tonly:%s\n' "$l" "$l" >> "$W/dec2"; done
  mv "$W/dec2" "$DEC"
fi
SELECTED="$(cut -f1 "$DEC" | awk '!s[$0]++' | awk 'BEGIN{o["reviewer"]=1;o["test"]=2;o["security"]=3;o["db"]=4;o["contract"]=5} {print o[$0]"\t"$0}' | sort -n | cut -f2)"
# a lane that is selected is never also skipped
: > "$W/skp2"
while IFS="$T" read -r l r; do printf '%s\n' "$SELECTED" | grep -qx -- "$l" || printf '%s\t%s\n' "$l" "$r" >> "$W/skp2"; done < "$SKP"
awk -F"$T" '!s[$1]++' "$W/skp2" > "$SKP"
# the reviewer's enforcement items: those no lane prefix claims, plus those of a lane that is not run this round
ENF_REV="$W/enf_rev"; : > "$ENF_REV"
while IFS= read -r item; do
  [ -n "$item" ] || continue
  ls_="$(awk -F"$T" -v i="$item" '$2==i {print $1}' "$ENF_ROUTED" | head -1)"
  if [ -z "$ls_" ]; then printf '%s\n' "$item" >> "$ENF_REV"
  elif ! printf '%s\n' "$SELECTED" | grep -qx -- "$ls_"; then printf '%s (lane %s not run: escalate: %s if hit)\n' "$item" "$ls_" "$ls_" >> "$ENF_REV"; fi
done < "$ENF"

LARGE=false
{ [ "${DIFF_LINES:-0}" -gt "$LARGE_LINES" ] || [ "${NFILES:-0}" -gt "$LARGE_FILES" ]; } && LARGE=true

# ---- packs --------------------------------------------------------------------------------------------
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
lane_files() { # files a lane reviews: its signal files; all FILES for reviewer/test or an enforcement-only lane
  local lane="$1"
  case "$lane" in reviewer|test) cat "$FILES"; return ;; esac
  if grep "^$lane$T" "$SIG" | cut -f3 | grep -q .; then grep "^$lane$T" "$SIG" | cut -f3 | grep . | sort -u
  else cat "$FILES"; fi
}
test_command() {
  local tests
  tests="$(grep -E '/src/test/.*(Test|Tests|IT)\.(java|kt)$|^src/test/.*(Test|Tests|IT)\.(java|kt)$' "$FILES" | sed -e 's#.*/##' -e 's#\.[a-z]*$##' | sort -u | head -12)"
  if [ -x "$REPO/gradlew" ] || [ -f "$REPO/build.gradle" ] || [ -f "$REPO/build.gradle.kts" ]; then
    printf '%s' "./gradlew test"; for t in $tests; do printf " --tests '*%s'" "$t"; done; echo
  elif [ -f "$REPO/pom.xml" ]; then
    if [ -n "$tests" ]; then printf './mvnw test -Dtest=%s\n' "$(printf '%s' "$tests" | tr '\n' ',' | sed 's/,$//')"; else echo "./mvnw test"; fi
  else
    echo "(no gradle/maven build found at the repo root — run the project's own test command)"
  fi
  echo "Report the exact command and the real pass/fail counts; run it fresh."
}
write_pack() { # $1 lane → prints "<path> <lines>"
  local lane="$1" p="$OUT/r$ROUND.$1.md" lf="$W/lf.$1" fixed="$W/fixed.$1" body="$W/body.$1" over="$W/over.$1"
  local depth=standard budget used n f fl lines
  lane_files "$lane" > "$lf"
  [ "$lane" != reviewer ] && [ "$lane" != test ] && grep -q "^$lane$T" "$ENF_ROUTED" && depth=deep
  [ "$lane" = security ] && grep "^security$T" "$DEC" | grep -qE 'path:(security|auth)/|SecurityConfig|Filter\.java|SecurityFilterChain|JwtDecoder|PasswordEncoder|PreAuthorize|Secured' && depth=deep
  printf '%s\n' "$depth" > "$W/depth.$lane"
  {
    echo "---"
    echo "base_sha: $BASE_SHA"; echo "head_sha: ${HEAD_SHA:-none}"; echo "reviewed_tree: $TREE"
    echo "round: $ROUND"; echo "route: $ROUTE"; echo "lane: $lane"; echo "agent: $(agent_of "$lane")"; echo "depth: $depth"
    echo "reasons:"; grep "^$lane$T" "$DEC" | cut -f2 | sed 's/^/  - /' | head -20
    n="$(grep -c . "$lf" || true)"; echo "files:  # $n"; head -40 "$lf" | sed 's/^/  - /'
    [ "$n" -gt 40 ] && echo "files_more: $((n-40))"
    echo "---"; echo
    echo "Reproduce any hunk: \`git diff $BASE_SHA $TREE -- <file>\` (pinned; never diff against the moving HEAD)."; echo
    echo "## Rigor"
    if [ -f "$PLUGIN_ROOT/skills/review/references/review-rigor.md" ]; then head -80 "$PLUGIN_ROOT/skills/review/references/review-rigor.md"; else echo "(review-rigor.md not found)"; fi
    echo; echo "## Known pitfalls"
    kp=""
    if [ -f "$PLUGIN_ROOT/scripts/inject-learnings.sh" ]; then
      kp="$(CLAUDE_PROJECT_DIR="$PROJECT" bash "$PLUGIN_ROOT/scripts/inject-learnings.sh" --filter "$(sed 's#.*/##; s#\.[A-Za-z]*$##' "$lf" | tr '\n' ' ')" --top 8 --max-len 200 2>/dev/null | head -40)"
    fi
    if [ -n "$kp" ]; then printf '%s\n' "$kp"; else echo "none matched"; fi
    echo; echo "## Enforcement"
    if [ "$lane" = reviewer ]; then
      if [ -s "$ENF_REV" ]; then sed 's/^/- /' "$ENF_REV"; else echo "none (fall back to the defect floor)"; fi
    elif grep -q "^$lane$T" "$ENF_ROUTED"; then grep "^$lane$T" "$ENF_ROUTED" | cut -f2 | sed 's/^/- /'
    else echo "none for this lane (fall back to the defect floor)"; fi
    if [ "$lane" = reviewer ]; then
      echo; echo "## Vocabulary"
      if [ -f "$PLANE/LANGUAGE.md" ]; then grep '^|' "$PLANE/LANGUAGE.md" | head -30; else echo "no LANGUAGE.md"; fi
      echo; echo "## Reuse suspects"
      if [ -n "$TASK_ID" ] && [ -f "$PLANE/tasks/$TASK_ID/reuse-scan.md" ]; then
        grep -iE 'suspect|reuse|duplicate' "$PLANE/tasks/$TASK_ID/reuse-scan.md" | head -20
      else echo "none recorded"; fi
      echo; echo "## Escalate"
      echo "A defect in the class of a lane that did not run, or that ran on a subset not covering its file: write \`escalate: <lane> — File.java:NN\` instead of reviewing it."
      echo "Lanes not run this round: $(cut -f1 "$SKP" | tr '\n' ' ')"
      if [ -s "$PARTIAL" ]; then
        echo "Lanes run on a subset (escalate for their class in these files):"
        for pl in $(cut -f1 "$PARTIAL" | awk '!s[$0]++'); do
          # print the shorter side: ≤20 uncovered → name them; else ≤20 covered → name those; else 20 uncovered + a count
          pn="$(grep -c "^$pl$T" "$PARTIAL")"; cn="$(grep -c . "$W/pf.$pl" || true)"
          if [ "$pn" -le 20 ]; then
            printf -- '- %s not covered: %s\n' "$pl" "$(grep "^$pl$T" "$PARTIAL" | cut -f2 | paste -sd ',' - | sed 's/,/, /g')"
          elif [ "$cn" -le 20 ]; then
            printf -- '- %s covered only: %s; every other file in this diff is uncovered for %s\n' "$pl" \
              "$(paste -sd ',' - < "$W/pf.$pl" | sed 's/,/, /g')" "$pl"
          else
            printf -- '- %s not covered: %s (+%s more — see lanes.json partial)\n' "$pl" \
              "$(grep "^$pl$T" "$PARTIAL" | cut -f2 | head -20 | paste -sd ',' - | sed 's/,/, /g')" "$((pn - 20))"
          fi
        done
      fi
    fi
    if grep -qE "io\.f8a\.summer|summer\." "$HUNKS" 2>/dev/null; then
      echo; echo "## Summer KB"
      if [ -d "$REPO/.claude/summer-kb" ]; then ls "$REPO/.claude/summer-kb" | head -10 | sed 's#^#- .claude/summer-kb/#'
      else echo "diff touches io.f8a.summer / summer.* — no local .claude/summer-kb/ (see summer-kb-setup)"; fi
    fi
    if [ "$lane" = test ] || { [ "$lane" = reviewer ] && [ "$ROUTE" = light ]; }; then
      echo; echo "## Test command"; test_command
    elif [ "$lane" = reviewer ]; then
      echo; echo "## Tests (not yours)"; echo "Not yours: claudehut-test-runner is the single test source on the full route — do not run build/test."
    fi
  } > "$fixed"
  : > "$body"; : > "$over"
  if [ "$lane" != test ]; then
    n="$(grep -c . "$lf" || true)"
    budget=$(( MAX_PACK_LINES - $(wc -l < "$fixed") - 8 - (n < 40 ? n : 40) ))
    awk -F"$T" -v budget="$budget" -v D="$W/fd" -v BODY="$body" -v OVER="$over" -v B="$BASE_SHA" -v TR="$TREE" '
      NR == FNR { n[$1]=$2; l[$1]=$3; k[$1]=$4; m[$1]=$5; next }
      $0 == "" || !($0 in n) || n[$0] == "" { next }                       # no textual difference (e.g. mode only)
      k[$0] == "bin" { print "- " $0 " (binary)" > OVER; next }
      k[$0] == "del" { print "- " $0 " (deletion only, -" m[$0] " lines)" > OVER; next }
      used + l[$0] <= budget { f = D "/" n[$0]; while ((getline x < f) > 0) print x > BODY; close(f); used += l[$0]; next }
      { print "- " $0 " (" l[$0] " diff lines, not inlined: run git diff " B " " TR " -- " $0 ")" > OVER }' "$W/fd.idx" "$lf"
  fi
  {
    cat "$fixed"
    if [ "$lane" != test ]; then
      echo; echo "## Diff"
      if [ -s "$body" ]; then echo '```diff'; cat "$body"; echo '```'; else echo "(no inlined hunks)"; fi
      if [ -s "$over" ]; then
        echo; echo "### Not inlined"; head -40 "$over"
        [ "$(wc -l < "$over")" -gt 40 ] && echo "- …and $(( $(wc -l < "$over") - 40 )) more; see files: in the header"
      fi
    fi
  } > "$p"
  lines="$(wc -l < "$p" | tr -d ' ')"
  if [ "$lines" -gt "$MAX_PACK_LINES" ]; then head -n "$MAX_PACK_LINES" "$p" > "$W/cut" && mv "$W/cut" "$p"; lines="$MAX_PACK_LINES"; fi
  printf '%s %s\n' "$p" "$lines"
}

# partial lanes: a signal-selected specialist lane packs only its signal files; the diff's other source files are
# not covered by it, and the reviewer escalates that lane's class there (08 §3.2, decided 2026-10-01: option (a))
PARTIAL="$W/partial"; : > "$PARTIAL"   # lane<TAB>file
for lane in $SELECTED; do
  case "$lane" in reviewer|test) continue ;; esac
  lane_files "$lane" > "$W/pf.$lane"
  # main sources first, test sources after (the pack lists at most 20 per lane)
  { grep -vE '(^|/)src/test/' "$FILES"; grep -E '(^|/)src/test/' "$FILES"; } | while IFS= read -r f; do
    [ -n "$f" ] && is_source "$f" && ! grep -qxF -- "$f" "$W/pf.$lane" && printf '%s\t%s\n' "$lane" "$f"
  done >> "$PARTIAL"
done

LANES_JSON="$W/lanes.jsonl"; : > "$LANES_JSON"
for lane in $SELECTED; do
  res="$(write_pack "$lane")"; pk="${res% *}"; ln="${res##* }"
  grep "^$lane$T" "$DEC" | cut -f2 | jq -Rsc --arg l "$lane" --arg a "$(agent_of "$lane")" --arg p "$pk" --argjson n "$ln" \
    --arg d "$(cat "$W/depth.$lane" 2>/dev/null || echo standard)" \
    '{lane:$l, name:$l, agent:$a, reasons:(split("\n")|map(select(length>0))|unique), depth:$d, pack:$p, lines:$n}' >> "$LANES_JSON"
done

ASK=false; ASK_REASON=""
if $LARGE; then ASK=true; ASK_REASON="large diff (${DIFF_LINES} lines, ${NFILES} files > ${LARGE_LINES}/${LARGE_FILES}): split with --paths | run every lane | reviewer+security only"; fi

jq -nc --argjson r "$ROUND" --arg route "$ROUTE" --arg task "$TASK_ID" --arg base "$BASE" --arg bsrc "$BASE_SRC" \
  --arg bsha "$BASE_SHA" --arg hsha "${HEAD_SHA:-}" --arg tree "$TREE" --arg out "$OUT" \
  --argjson nf "${NFILES:-0}" --argjson dl "${DIFF_LINES:-0}" \
  --slurpfile lanes "$LANES_JSON" \
  --rawfile skp "$SKP" --rawfile part "$PARTIAL" --rawfile unc "$UNCOV" --rawfile enfr "$ENF_ROUTED" --rawfile excl "$EXCL" \
  --argjson large "$LARGE" --argjson ask "$ASK" --arg askr "$ASK_REASON" \
  --argjson deg "$DEGRADED" --arg degr "$DEGR" '
  {round:$r, route:$route, task:(if $task=="" then null else $task end), base:$base, base_source:$bsrc,
   base_sha:$bsha, head_sha:(if $hsha=="" then null else $hsha end), head_tree:$tree, reviewed_tree:$tree,
   out_dir:$out, files:$nf, diff_lines:$dl, lanes:$lanes,
   skipped:($skp|split("\n")|map(select(length>0)|split("\t")|{lane:.[0], name:.[0], reason:.[1], why:.[1]})),
   partial:($part|split("\n")|map(select(length>0)|split("\t")) | group_by(.[0]) | map({lane:.[0][0], uncovered:map(.[1])})),
   uncovered:($unc|split("\n")|map(select(length>0))),
   hints:($enfr|split("\n")|map(select(length>0)|split("\t")|{lane:.[0], reason:("enf:"+.[1])})),
   excluded:($excl|split("\n")|map(select(length>0))|.[0:40]), excluded_count:($excl|split("\n")|map(select(length>0))|length),
   large:$large, ask_user:$ask, ask_reason:$askr, capped:false, degraded:$deg, degraded_reason:$degr}' > "$W/out.json" \
  || fallback "jq failed assembling the output"
cp "$W/out.json" "$OUT/lanes.r$ROUND.json" 2>/dev/null; cp "$W/out.json" "$OUT/lanes.json" 2>/dev/null
cat "$W/out.json"
exit 0
