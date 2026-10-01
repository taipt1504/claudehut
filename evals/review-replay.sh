#!/usr/bin/env bash
# review-replay.sh — replay scripts/review-pack.sh on real ewallet tasks (08-review.md AC10; 10-rollout-eval.md §5
# "Fan-out review" and "Recall review"). READ-ONLY on the ewallet repos: review-pack runs with --head (committed
# tree, no snapshot, no temp-index `git add`, no untracked scan), so the only git verbs that touch a repo are
# rev-parse and diff; packs and the synthetic task.json live in a temp plane. The script proves it afterwards:
# nothing under <repo>/.git is newer than a marker taken before the run.
#
# Usage: evals/review-replay.sh [--json] [--manifest FILE] [--root DIR]
#        evals/review-replay.sh --frame COST_JSON [--root DIR]   (COST_JSON = `evals/review-cost.sh --json` output)
#   --manifest  default evals/tasks/review-pack/replay.json (task → diff range, v0.11 dispatch count, MED+ findings)
#   --root      ewallet workspace (default $EWALLET_ROOT or ~/Documents/Projects/ewallet-workspace); missing → SKIP
#
# Per task, two selector runs: `signals` (paths + hunks only) and `+enf` (plus the enforcement set recovered from the
# review.md coverage table — rule-file names such as framework/r2dbc.md in the first cell of a row).
# Fan-out  = auditors the selector dispatches (lanes incl. test-runner) vs the v0.11 round-1 dispatch count.
# Recall   = each MED+ finding's defect class → lane (security→security, db|perf→db, contract|observability→
#            contract, the rest → reviewer floor). Buckets, file-level (the finding's file = `file`, else a `locus`
#            that names one file): lane (that lane selected and the file not in its `partial[].uncovered`; a finding
#            with no file named counts here as "unlocated") · floor (reviewer class, the reviewer always runs) ·
#            escalate (lane skipped, or selected but partial on the file; only the reviewer's escalate — "Lanes not
#            run" / "Lanes run on a subset" — can recover it; counted
#            toward the 08 target "lane or escalate" but shown apart because it is not guaranteed) · out-of-diff
#            (pre-existing outside the reviewed diff; not in the diff-scope denominator) · not-in-diff (a lane-class
#            finding names a file outside the range, e.g. an SDK type in another repo; not in the denominator either).
#            Every in-scope finding lands in lane, floor or escalate, so "incl. escalate" is 100% BY CONSTRUCTION and
#            "floor" holds by definition (the reviewer always runs): neither is a measurement. The measured parts are
#            lane|floor (informational) and fixture coverage: each escalate-only finding must be named by the `covers`
#            field ("<repo> <task>#<id>", a string or an array) of a case under evals/tasks/review-pack/cases/ (AC10).
#            A fixture pins that the lane is skipped, or partial on the file, and that the reviewer's pack names it
#            under ## Escalate; it cannot show the reviewer writes
#            the escalate line.
#
# SAMPLE (replay.json, 22 tasks, stratified; decision 2026-10-01 in 08-review.md §9). Frame = the 52 v0.11
# review waves evals/review-cost.sh reads from the ewallet transcripts (2026-08-20..09-25). A wave is matched to a
# task by repo + time (wave start just before the task commit, same topic); its measured dispatch count and kinds
# are `historical` (source names the session + wave start). Where review.md disagrees the transcript wins
# (PO 0001: 6 not 5). The frame holds almost no small diffs — small tasks were folded into multi-task commits —
# so small/light-like tasks come from before the window with `source: review.md`, including 0-dispatch
# main-thread reviews. Kept only when the range is reconstructable: head = parent of the first review-fix
# commit, or the single task commit (then it may carry the round-1 fixes); base = parent of the first task
# commit. Checked against review.md: file names for the pre-window rows (misses: wallet 0009 VaStatus.java,
# party 0021 AMLCaseMonitorEventHandler.java); shortstat, scope line or commit timing vs wave start for the
# core-ledger, pg 0094/0095/0100 and PO 0004 rows. Tasks with and without MED+ findings are both kept. Dropped:
# va 0032 (squashed into a 140-file commit), pg 0026 (folded into a9e55be), pg 0098 (no commit matches its wave),
# auth 0021 (range pulls in 0020's hierarchy files), auth 0017 (same files as 0018; one kept).
# Route: v0.11 tier small|trivial|main-thread → light, full (incl. escalated) → full.
# Strata, computed here from the pack's own files/diff_lines: small = ≤3 files and ≤150 diff lines;
# large = review-pack's `large` (>1500 lines or >30 files, LARGE_LINES/LARGE_FILES); medium = the rest.
# Replay is round 1 only. The review-cost baseline (28/52 waves ≥4) also counts round-2 waves.
# Fan-out share = tasks whose round-1 wave has ≥4 lanes / tasks (0-dispatch v0.11 reviews stay in the
# denominator). Target (08 §9): ≤25% of all waves; large full-route diffs may use ≥4, but still count.
#
# FRAME (--frame): projects the fan-out share onto the 52-wave frame instead of the sample. The selector puts ≥4
# lanes on `large` diffs only (sample: every large task ≥4, every small/medium <4), so the share is the share of
# waves reviewing a large diff. Proxy per wave: the first non-merge commit (any branch) committed after the wave
# start in that repo, sized by its shortstat (large = >1500 lines or >30 files). Waves pairing to the same commit
# are one task: the first is round 1, the rest round 2+. Lower bound = round-1 waves on a large commit; upper bound
# = every wave on a large commit (a selector round 2 is carry ∪ fix lanes, so it need not reach 4). Squashed
# multi-task commits inflate "large", so the upper bound is conservative. Check: waves named by a manifest task's
# `historical.source` (session + start) are compared with that task's own range shortstat.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RP="$ROOT/scripts/review-pack.sh"
MANIFEST="$ROOT/evals/tasks/review-pack/replay.json"
EW="${EWALLET_ROOT:-$HOME/Documents/Projects/ewallet-workspace}"
AS_JSON=false
while [ $# -gt 0 ]; do
  case "$1" in
    --json) AS_JSON=true; shift ;;
    --manifest) MANIFEST="$2"; shift 2 ;;
    --root) EW="$2"; shift 2 ;;
    --frame) FRAME="$2"; shift 2 ;;
    *) shift ;;
  esac
done
command -v jq >/dev/null 2>&1 || { echo "SKIP - jq not found"; exit 0; }
[ -d "$EW" ] || { echo "SKIP - no ewallet workspace at $EW"; exit 0; }

size() { # <repo> <rev-args…> → "files lines"
  local ss; ss="$(git -C "$1" diff --shortstat "${@:2}" 2>/dev/null)"
  printf '%s %s\n' "$(grep -oE '^ *[0-9]+' <<<"$ss" | tr -d ' ' || true)" \
    "$(( $(grep -oE '[0-9]+ insert' <<<"$ss" | grep -oE '[0-9]+' || echo 0) + $(grep -oE '[0-9]+ delet' <<<"$ss" | grep -oE '[0-9]+' || echo 0) ))"
}
if [ -n "${FRAME:-}" ]; then
  W_FRAME="$(mktemp)"; trap 'rm -f "$W_FRAME"' EXIT
  jq -r '.per_wave[] | [.project, .start, .auditors, .session] | @tsv' "$FRAME" | while IFS="$(printf '\t')" read -r p st a se; do
    c="$(git -C "$EW/$p" log --all --no-merges --reverse --since="$st" --format=%h 2>/dev/null | head -1)"
    read -r f l <<<"$( [ -n "$c" ] && size "$EW/$p" "$c^" "$c" || echo "0 0")"
    chk="$(jq -r --arg k "$se $st" '[.tasks[] | select((.historical.source // "") | contains($k)) | "\(.repo) \(.base) \(.head)"] | first // ""' "$MANIFEST")"
    tl=""; [ -n "$chk" ] && { set -- $chk; read -r tf tn <<<"$(size "$EW/$1" "$2" "$3")"; tl="$([ "${tn:-0}" -gt 1500 ] || [ "${tf:-0}" -gt 30 ] && echo true || echo false)"; }
    jq -nc --arg p "$p" --arg st "$st" --argjson a "$a" --arg c "$c" --argjson f "${f:-0}" --argjson l "${l:-0}" --arg tl "$tl" \
      '{project:$p, start:$st, auditors:$a, commit:$c, files:$f, lines:$l, large:($l > 1500 or $f > 30), task_large:(if $tl=="" then null else ($tl=="true") end)}'
  done | jq -sc 'def pct(a; b): ((a * 1000 / b) | round / 10);
    (group_by([.project, .commit]) | map(sort_by(.start) | to_entries | map(.value + {round1: (.key == 0)})) | add) as $w
    | ($w | length) as $n | ($w | map(select(.task_large != null))) as $v
    | {waves: $n, round1_waves: ($w | map(select(.round1)) | length),
       large_round1: ($w | map(select(.large and .round1)) | length), large_all: ($w | map(select(.large)) | length),
       v011_ge4: ($w | map(select(.auditors >= 4)) | length),
       checked: ($v | length), check_agree: ($v | map(select(.large == .task_large)) | length),
       check_disagree: ($v | map(select(.large != .task_large) | "\(.project) \(.start) proxy \(.files)f/\(.lines)l, task large=\(.task_large)")),
       waves_detail: $w}
    | . + {ge4_lower_pct: pct(.large_round1; .waves), ge4_upper_pct: pct(.large_all; .waves)}' > "$W_FRAME" 2>/dev/null
  if $AS_JSON; then cat "$W_FRAME"; exit 0; fi
  jq -r '"== fan-out projected on the \(.waves)-wave frame (\(.round1_waves) round-1 waves; v0.11 \(.v011_ge4)/\(.waves) ≥4)",
         "  large-diff waves: round 1 \(.large_round1)/\(.waves) (\(.ge4_lower_pct)%, lower bound) · all \(.large_all)/\(.waves) (\(.ge4_upper_pct)%, upper bound)",
         "  proxy check vs manifest task ranges: \(.check_agree)/\(.checked) agree" + (if (.check_disagree|length)>0 then "; disagree: \(.check_disagree|join("; "))" else "" end)' "$W_FRAME"
  exit 0
fi

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
export TMPDIR="$W/tmp"; mkdir -p "$TMPDIR"
unset CLAUDEHUT_SESSION_ID CLAUDEHUT_FEDERATION_ROOT
: > "$W/rows.jsonl"
n="$(jq '.tasks | length' "$MANIFEST")"
for i in $(seq 0 $((n - 1))); do
  t="$(jq -c ".tasks[$i]" "$MANIFEST")"
  repo="$EW/$(jq -r .repo <<<"$t")"; id="$(jq -r .task <<<"$t")"
  base="$(jq -r .base <<<"$t")"; head="$(jq -r .head <<<"$t")"; route="$(jq -r .route <<<"$t")"
  rmd="$repo/.claude/claudehut/tasks/$id/review.md"
  if ! git -C "$repo" rev-parse -q --verify "$base^{commit}" >/dev/null 2>&1 || ! git -C "$repo" rev-parse -q --verify "$head^{commit}" >/dev/null 2>&1; then
    jq -nc --arg id "$id" '{task:$id, error:"range does not resolve"}' >> "$W/rows.jsonl"; continue
  fi
  enf='[]'
  [ -f "$rmd" ] && enf="$(awk -F'|' '/^\|/ {c=$2; gsub(/[` *]/,"",c); if (c ~ /^[a-z-]+\/[a-z0-9-]+\.md$/) print c}' "$rmd" | sort -u | jq -Rsc 'split("\n")|map(select(length>0))')"
  marker="$W/marker.$i"; : > "$marker"; sleep 1   # mtime granularity: anything written under .git after this is newer
  for mode in signals enf; do
    P="$W/plane.$i.$mode"; mkdir -p "$P/.claude/claudehut/tasks/replay"
    e='[]'; [ "$mode" = enf ] && e="$enf"
    jq -nc --arg r "$route" --argjson e "$e" '{schema:2,id:"replay",route:$r,base:{},pre_dirty:{},enforcement_set:$e}' \
      > "$P/.claude/claudehut/tasks/replay/task.json"
    CLAUDE_PROJECT_DIR="$P" bash "$RP" --repo "$repo" --base "$base" --head "$head" --route "$route" --task replay \
      --out "$W/out.$i.$mode" > "$W/sel.$i.$mode.json" 2>/dev/null || true
  done
  written="$(find "$repo/.git" -newer "$marker" -print 2>/dev/null | head -3 | tr '\n' ' ')"
  # the diff's file list, uncapped (read-only `git diff --name-only`), for file-level recall
  git -C "$repo" diff --no-renames --name-only "$base" "$head" 2>/dev/null | jq -Rsc 'split("\n")|map(select(length>0))' > "$W/df.$i.json"
  jq -nc --argjson t "$t" --slurpfile s "$W/sel.$i.signals.json" --slurpfile e "$W/sel.$i.enf.json" \
     --slurpfile df "$W/df.$i.json" \
     --argjson enf "$enf" --arg written "$written" '
    def lane_of: if . == "security" then "security" elif (. == "db" or . == "perf") then "db"
                 elif (. == "contract" or . == "observability") then "contract" else "reviewer" end;
    def rep_lane: (sub("-reviewer$";"") | sub("-auditor$";"") | sub("^general$";"reviewer")) as $r
                 | if $r == "perf" then "db" elif $r == "observability" then "contract" elif $r == "main" then null else $r end;
    # file-level: the file of a finding is `file`, else `locus` (a basename or a path). A file named but not in the
    # diff → not-in-diff (e.g. a cited SDK type in another repo). A selected lane whose `partial[].uncovered` holds
    # the file did not see it → escalate (the "Lanes run on a subset" line of the reviewer pack). No file → lane (unlocated).
    def matches($x): any(. == $x or endswith("/" + $x));
    def fname: (.file // .locus // "") | if test("^[^ ]+\\.[A-Za-z]+$") then . else "" end;
    def recall($lanes; $partial): .findings | map(. as $f | ($f.class | lane_of) as $l | ($f | fname) as $x
       | (($partial | map(select(.lane == $l)) | .[0].uncovered) // []) as $unc
       | (if ($f.scope // "") == "out-of-diff" then "out-of-diff"
          elif $l == "reviewer" then "floor"
          elif $x != "" and (($df[0] // []) | matches($x) | not) then "not-in-diff"
          elif ($lanes | index($l)) == null then "escalate"
          elif $x != "" and ($unc | matches($x)) then "escalate" else "lane" end) as $b
       | $f + {lane: $l, reporter_lane: ($f.reporter | rep_lane), bucket: $b,
               lane_state: (if $l == "reviewer" then null elif ($lanes | index($l)) == null then "skipped"
                            elif $x != "" and ($unc | matches($x)) then "partial"
                            elif $x == "" then "unlocated" else "covered" end)});
    ($s[0] // {}) as $S | ($e[0] // {}) as $E
    | ($S.lanes // [] | map(.lane)) as $ls | ($E.lanes // [] | map(.lane)) as $le
    | {task: $t.task, repo: $t.repo, range: "\($t.base)..\($t.head)", route: $t.route,
       stratum: (if $E.large == true then "large" elif (($E.files // 99) <= 3 and ($E.diff_lines // 9999) <= 150) then "small" else "medium" end),
       files: $E.files, diff_lines: $E.diff_lines, large: $E.large, ask_user: $E.ask_user, degraded: (if $E.degraded == null then true else $E.degraded end),
       enforcement_items: ($enf | length),
       historical: $t.historical.round1_dispatches, historical_kinds: $t.historical.kinds,
       lanes_signals: $ls, lanes_enf: $le, fanout_signals: ($ls | length), fanout_enf: ($le | length),
       max_pack_lines: ([$E.lanes[]?.lines] | max // 0),
       reasons: ($E.lanes // [] | map({(.lane): (.reasons | .[0:4])}) | add),
       partial_enf: ($E.partial // []), findings: ($t | recall($le; ($E.partial // []))), findings_signals: ($t | recall($ls; ($S.partial // []))),
       repo_written: $written}' >> "$W/rows.jsonl"
done

COVERS="$(cat "$ROOT"/evals/tasks/review-pack/cases/*/case.json | jq -sc '[.[].covers // empty] | flatten')"
SUMMARY="$(jq -sc --argjson covers "$COVERS" '
  def pct(a; b): if b == 0 then null else ((a * 1000 / b) | round / 10) end;
  def agg(k): [.[] | .[k][]? | select(.bucket != "out-of-diff" and .bucket != "not-in-diff")] as $f
    | {med_plus: ($f|length), lane: ($f|map(select(.bucket=="lane"))|length), floor: ($f|map(select(.bucket=="floor"))|length),
       escalate: ($f|map(select(.bucket=="escalate"))|length)}
    | . + {recall_lane_or_floor_pct: pct(.lane + .floor; .med_plus), recall_incl_escalate_pct: pct(.lane + .floor + .escalate; .med_plus)};
  def fan: {n: length,
             historical_dispatches: (map(.historical)|add // 0), selected_dispatches_enf: (map(.fanout_enf)|add // 0),
             selected_dispatches_signals: (map(.fanout_signals)|add // 0),
             historical_ge4: (map(select(.historical>=4))|length), selected_ge4_enf: (map(select(.fanout_enf>=4))|length),
             selected_ge4_signals: (map(select(.fanout_signals>=4))|length)}
    | . + {historical_ge4_pct: pct(.historical_ge4; .n), selected_ge4_enf_pct: pct(.selected_ge4_enf; .n),
           selected_ge4_signals_pct: pct(.selected_ge4_signals; .n)};
  map(select(.error == null)) as $r
  | ($r|fan) + {tasks: ($r|length),
     by_stratum: (["small","medium","large"] | map(. as $k | {($k): ($r | map(select(.stratum==$k)) | fan + {recall_enf: agg("findings")})}) | add),
     excl_large_full: ($r | map(select((.stratum=="large" and .route=="full")|not)) | fan),
     by_route: (["light","full"] | map(. as $k | {($k): ($r | map(select(.route==$k)) | fan)}) | add),
     recall_enf: ($r|agg("findings")), recall_signals: ($r|agg("findings_signals")),
     out_of_diff: ([$r[].findings[] | select(.bucket=="out-of-diff")] | length),
     not_in_diff: [$r[] | .task as $t | .findings[] | select(.bucket=="not-in-diff") | "\($t)#\(.id) \(.file // .locus)"],
     unlocated_lane: ([$r[].findings[] | select(.lane_state=="unlocated")] | length),
     escalate_only: [$r[] | .task as $t | .repo as $rp | .findings[] | select(.bucket=="escalate")
                     | {task:$t, id, severity, class, reporter, lane_state, fixture: (("\($rp) \($t)#\(.id)") as $k | $covers | index($k) != null)}],
     max_pack_lines: ($r|map(.max_pack_lines)|max), any_degraded: ($r|map(.degraded)|any),
     repos_written: [$r[] | select(.repo_written != "") | {task, repo_written}],
     errors: [.[] | select(.error != null)]}
  | . + {escalate_without_fixture: [.escalate_only[] | select(.fixture | not) | "\(.task)#\(.id)"]}' "$W/rows.jsonl")"

if $AS_JSON; then jq -sc --argjson s "$SUMMARY" '{summary:$s, tasks:.}' "$W/rows.jsonl"; exit 0; fi
echo "== review-pack replay ($(jq .tasks <<<"$SUMMARY") ewallet tasks, read-only)"
jq -r '"  \(.task) [\(.stratum)/\(.route) · \(.repo) \(.range), \(.files) files/\(.diff_lines) lines\(if .large then ", LARGE→ask" else "" end)]\n" +
       "    v0.11 dispatched \(.historical) (\(.historical_kinds|join(",")))\n" +
       "    selector signals: \(.fanout_signals) [\(.lanes_signals|join(","))] · +enf(\(.enforcement_items) items): \(.fanout_enf) [\(.lanes_enf|join(","))] · max pack \(.max_pack_lines) lines\n" +
       "    MED+: " + ([.findings[] | "\(.id)=\(.bucket)"] | join(" ")) +
       (if .repo_written != "" then "\n    WARNING repo written: \(.repo_written)" else "" end)' "$W/rows.jsonl"
jq -r 'def f: "v0.11 \(.historical_dispatches) dispatches, \(.historical_ge4)/\(.n) ≥4 (\(.historical_ge4_pct)%) → selector +enf \(.selected_dispatches_enf), \(.selected_ge4_enf)/\(.n) ≥4 (\(.selected_ge4_enf_pct)%) · signals-only \(.selected_dispatches_signals), \(.selected_ge4_signals)/\(.n) ≥4 (\(.selected_ge4_signals_pct)%)";
       def r: "lane \(.lane) · floor \(.floor) · escalate \(.escalate) of \(.med_plus) MED+";
       "  fan-out, all waves: " + f,
       (.by_stratum | to_entries[] | "    \(.key): " + (.value|f) + "\n      recall +enf: " + (.value.recall_enf|r)),
       (.by_route | to_entries[] | "    route \(.key): " + (.value|f)),
       "    (secondary) excluding large full-route: " + (.excl_large_full|f),
       "  recall +enf (diff scope, \(.recall_enf.med_plus) MED+): lane \(.recall_enf.lane) · floor \(.recall_enf.floor) · escalate-only \(.recall_enf.escalate) → lane|floor \(.recall_enf.recall_lane_or_floor_pct)% · incl. escalate \(.recall_enf.recall_incl_escalate_pct)% (100% by construction, not a measurement)",
       "  recall signals-only: lane|floor \(.recall_signals.recall_lane_or_floor_pct)% · incl. escalate \(.recall_signals.recall_incl_escalate_pct)% (by construction)",
       "  out-of-diff (pre-existing, not in the denominator): \(.out_of_diff) · not-in-diff (file outside the range, not in the denominator): \(.not_in_diff|length) \(.not_in_diff) · lane with no file named (unlocated): \(.unlocated_lane)",
       "  escalate-only findings (each needs a fixture `covers`): " + (if (.escalate_only|length)==0 then "none" else (.escalate_only|map("\(.task)#\(.id) \(.severity) \(.class) (\(.reporter))")|join("; ")) end),
       "  escalate-only without a fixture (AC10 needs none): " + (if (.escalate_without_fixture|length)==0 then "none" else (.escalate_without_fixture|join("; ")) end),
       "  max pack lines: \(.max_pack_lines) · degraded runs: \(.any_degraded) · repos written: \(if (.repos_written|length)==0 then "none" else (.repos_written|tostring) end)",
       (if (.errors|length)>0 then "  errors: \(.errors|tostring)" else empty end)' <<<"$SUMMARY"
