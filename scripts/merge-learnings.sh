#!/usr/bin/env bash
# Deterministic learnings engine. Called by the capture-learnings skill (which has Bash) AFTER the
# learner agent returns its candidate extractions. Does the work that must NOT be an LLM reasoning task:
# normalize triggers, dedup by category+normalized-trigger, merge (hits++, confidence+0.05, ts=now) or
# append, PROMOTE proven pitfalls into rule files, PRUNE decayed noise. The learner used to do all of
# this by reasoning at xhigh effort — minutes of latency on a 2-line file. Here it is milliseconds and
# exact. See 07 §5 / agents/claudehut-learner.md.
#
# Usage: merge-learnings.sh --candidates PATH [--project NAME] [--ts ISO8601] [--session SID] [--injected FILE]
#        merge-learnings.sh --repair [--session SID]
#   --candidates PATH   JSONL of candidate learnings from the learner (07 §8.2). Each line:
#                       {category, trigger, learning, evidence, confidence?, scope?, supersedes?}. The body may
#                       arrive as `text`/`lesson` (normalized to `learning`); trigger in any form (normalized here:
#                       stopwords, `ms` and service-name tokens dropped, at most 5 tokens; confidence default 0.6).
#   --repair            no candidates needed: normalize the store's keys, move entries whose learning is empty to
#                       learnings.rejected.jsonl, then prune/cap as usual. Idempotent; every merge runs it too.
#   --project NAME      project tag for new entries (default: existing entries' project, else "unknown")
#   --ts ISO8601        timestamp for merged/new entries (default: now, UTC)
# Emits a one-line JSON report: {added, merged, fuzzy, promoted, dropped, rejected, repaired, recurred, applied,
# unmapped} (+ fleet: hub rows changed, only on a microservice plane with a hub). Rejected candidates go to state/<sid>.rejected.jsonl with the reason. After the write it refreshes
# the generated block of MEMORY.md (scripts/index/memory.py --no-migrate; only a file that already has markers).
# Never corrupts the store (atomic write); fails open (exit 0) when jq or the inputs are missing.
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo '{"added":0,"merged":0,"promoted":0,"dropped":0,"skipped":"no-jq"}'; exit 0; }

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
DIR="$PROJECT_DIR/.claude/claudehut"
LEARNINGS="$DIR/learnings.jsonl"
RULES_DIR="$PROJECT_DIR/.claude/rules"

CAND=""; PROJECT=""; TS=""; SID=""; INJECTED=""; REPAIR=false
while [ $# -gt 0 ]; do
  case "$1" in
    --candidates) CAND="${2:-}"; shift 2 ;;
    --project)    PROJECT="${2:-}"; shift 2 ;;
    --ts)         TS="${2:-}"; shift 2 ;;
    --session)    SID="${2:-}"; shift 2 ;;   # WS-6: write a per-session learn-receipt (proof a Learn pass ran)
    --injected)   INJECTED="${2:-}"; shift 2 ;;  # WS-6: ids injected at SessionStart → stamp .applied on resurface
    --repair)     REPAIR=true; shift ;;          # 07 §8.2 repair pass without candidates (D5)
    *) shift ;;
  esac
done

# WS-6: ids the SessionStart hook injected (a JSON array). When one of these learnings RESURFACES as a
# candidate this task, it was relevant → stamp .applied (the reinforcement signal the scoreboard reads).
# LRN-2: default --injected to the sidecar SessionStart already writes for this session. Every caller had
# to pass it explicitly and none did, so INJ_IDS was always [] and `.applied` could never be stamped — the
# inject-then-use loop was open in production while the eval, which passes the flag, stayed green.
[ -z "$INJECTED" ] && [ -n "$SID" ] && [ -f "$DIR/state/$SID.injected.json" ] && INJECTED="$DIR/state/$SID.injected.json"
INJ_IDS='[]'; [ -n "$INJECTED" ] && [ -f "$INJECTED" ] && INJ_IDS="$(jq '. // []' "$INJECTED" 2>/dev/null || echo '[]')"

if ! { [ -n "$CAND" ] && [ -f "$CAND" ]; }; then
  { $REPAIR && [ -f "$LEARNINGS" ]; } || { echo '{"added":0,"merged":0,"promoted":0,"dropped":0,"skipped":"no-candidates"}'; exit 0; }
  CAND=""
fi
[ -n "$TS" ] || TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
NOW="$(date -u +%s)"
mkdir -p "$DIR" 2>/dev/null || true

# ── ADVISORY LOCK (v0.9 Rec 1, audit MEM-1): learnings.jsonl is a single cross-session store and this is an
#    unlocked read-modify-write — two concurrent Learn passes would last-writer-win and silently drop the
#    loser's added entries + hit/applied stamps. Serialize with a portable mkdir-lock (atomic on POSIX; no
#    flock dependency, so it works on macOS too), a stale-lock breaker (a crashed writer's lock is stolen
#    after 30s), and a bounded spin so a wedged lock never HANGS the Learn phase (fail-open: proceed after the
#    cap). Released via EXIT trap. The whole read→merge→write below is the critical section.
LOCK="$LEARNINGS.lock"
# GNU stat first (on Linux `stat -f` is --file-system: a multi-line report + exit 1); non-numeric → 0 (never steal).
_lock_mtime() { local m; m="$(stat -c %Y "$1" 2>/dev/null)" || m="$(stat -f %m "$1" 2>/dev/null)" || m=0
                case "$m" in ''|*[!0-9]*) m=0 ;; esac; printf '%s' "$m"; }
_lock_held=""
release_lock() {
  case "$_lock_held" in
    mkdir) rm -rf "$LOCK" 2>/dev/null ;;
    flock) { exec 9>&-; } 2>/dev/null ;;   # closing the fd releases the flock
  esac
  _lock_held=""
}
acquire_lock() {
  # Prefer flock — a REAL blocking wait (deterministic; present on Linux/CI). fd 9 held for the run;
  # released on close/exit. -w 10 caps the wait, then proceeds (fail-open, never wedges).
  if command -v flock >/dev/null 2>&1; then
    # Brace-grouped (V3-5): a bare `exec 9>file 2>/dev/null` applies BOTH redirections to the shell for the rest
    # of the run, so every later jq/mv error of the merge went to /dev/null (bin/claudehut-state has the same guard).
    if { exec 9>"$LOCK.flock"; } 2>/dev/null && flock -w 10 9 2>/dev/null; then
      _lock_held="flock"; trap 'release_lock' EXIT INT TERM
    fi
    return 0
  fi
  # Fallback (e.g. macOS without flock): atomic mkdir-lock, stale-lock breaker (steal after 30s), bounded by
  # WALL-CLOCK not iteration count (iteration caps bail early on a fast/slow host — the CI MEM-1 failure).
  local start badpath; start="$(date -u +%s)"; badpath=0
  while ! mkdir "$LOCK" 2>/dev/null; do
    # Only a DIRECTORY is ever a valid lock here. A plain file at this path makes every mkdir fail, and
    # since the steal below is `-d`-guarded it is never cleared — so every Learn pass hot-spun to the full
    # 10s cap and then wrote unlocked. Measured: 0.13s normally, 10.03s at 62% CPU with a file planted,
    # on every single invocation, with the file still there afterwards. Clear it once, then retry.
    if [ -e "$LOCK" ] && [ ! -d "$LOCK" ]; then
      if [ "$badpath" = 0 ]; then badpath=1; rm -f "$LOCK" 2>/dev/null; continue; fi
      return 0
    fi
    local now; now="$(date -u +%s)"
    lm="$(_lock_mtime "$LOCK")"
    # steal ONLY on a real, genuinely old mtime: _lock_mtime falls back to 0 when stat loses a race with
    # the holder's rm, and treating that 0 as "ancient" steals an actively-held lock (same guard as
    # bin/claudehut-state, where it measured 11/25 lost updates under 4-way contention).
    if [ -d "$LOCK" ] && [ "${lm:-0}" -gt 0 ] && [ "$(( now - lm ))" -ge 30 ]; then
      rm -rf "$LOCK" 2>/dev/null; continue          # steal a stale lock (crashed/killed writer)
    fi
    if [ "$(( now - start ))" -ge 10 ]; then return 0; fi   # 10s wall-clock cap → proceed (fail-open)
    # Yield. Without this the wait was a HOT spin — the 10s cap above burned a core for ten seconds
    # rather than waiting for ten seconds. bin/claudehut-state's loop has always yielded here.
    sleep 0.02 2>/dev/null || true
  done
  _lock_held="mkdir"; trap 'release_lock' EXIT INT TERM
}
acquire_lock

# Load existing store + candidates as JSON arrays (tolerate absent/blank/garbage lines).
EXISTING='[]'; [ -f "$LEARNINGS" ] && EXISTING="$(jq -R 'fromjson? // empty' "$LEARNINGS" 2>/dev/null | jq -s '.' 2>/dev/null || echo '[]')"
CANDS='[]'; [ -n "$CAND" ] && [ -f "$CAND" ] && CANDS="$(jq -R 'fromjson? // empty' "$CAND" 2>/dev/null | jq -s '.' 2>/dev/null || echo '[]')"

# ── KEY NORMALIZATION + REPAIR (07 §8.2, D5): candidates that carried the body under `text` (or `lesson`) were
#    stored with learning:"" — 40 empty entries across the real stores. The body is the first NON-empty of
#    learning/text/lesson/summary (jq `//` does not fall through on ""), trimmed. `summary`: aml-service's 7 hand-written
#    v0.11 entries carry the body there, and the M7 migration dry-run would have moved all of them to rejected. The same rule repairs the store: an
#    entry that is still empty after it moves to learnings.rejected.jsonl (append — never deleted), so the
#    repair is idempotent. Runs on every merge; `--repair` runs it alone (no candidates needed).
# shellcheck disable=SC2016
JQ_BODY='def body: ([.learning, .text, .lesson, .summary] | map(select(type=="string") | sub("^\\s+"; "") | sub("\\s+$"; "")) | map(select(length > 0)) | first) // "";'
REPAIRED_JSON="$(jq -c "$JQ_BODY"'
  [ .[] | (body) as $b | if $b == "" then {bad: .} else {ok: (. + {learning: $b} | del(.text, .lesson, .summary))} end ]
  | {ok: [ .[] | .ok // empty ], bad: [ .[] | .bad // empty ]}' <<<"$EXISTING" 2>/dev/null || echo '')"
# Ids are never reused: a repaired (moved) entry keeps its id in learnings.rejected.jsonl, so the next id is
# max+1 over the store AND that file, taken before the repair.
MAXID="$( { printf '%s\n' "$EXISTING" | jq -c '.[]' 2>/dev/null; cat "$DIR/learnings.rejected.jsonl" 2>/dev/null || true; } \
  | jq -R 'fromjson? // empty | (.id // "") | tostring | capture("L-(?<n>[0-9]+)")? | .n | tonumber' 2>/dev/null \
  | jq -s 'max // 0' 2>/dev/null || echo 0)"
REPAIRED=0
if [ -n "$REPAIRED_JSON" ]; then
  REPAIRED="$(jq '.bad | length' <<<"$REPAIRED_JSON")"
  if [ "${REPAIRED:-0}" -gt 0 ]; then
    jq -c --arg ts "$TS" '.bad[] | . + {rejected_reason: "empty-learning", rejected_at: $ts}' <<<"$REPAIRED_JSON" \
      >> "$DIR/learnings.rejected.jsonl" 2>/dev/null || true
  fi
  EXISTING="$(jq -c '.ok' <<<"$REPAIRED_JSON")"
fi
# Hand-written v0.11 entries (aml-service) carry no id, confidence or hits and a date-only ts. Give them what a new
# entry gets (id max+1, confidence 0.6, hits 1, ts at that day's midnight): without it they cannot be excluded or
# stamped .applied, and PRUNE reads the missing confidence as 0 and retires them at 90 days. Idempotent.
FILLED="$(jq -c --argjson maxid "${MAXID:-0}" '
  def pad4: tostring | ("0000" + .)[-4:];
  reduce .[] as $e ({n: $maxid, out: []};
    ($e | if (.ts | type) == "string" and (.ts | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) then .ts += "T00:00:00Z" else . end
        | if has("confidence") then . else .confidence = 0.6 end
        | if has("hits") then . else .hits = 1 end) as $f
    | if (($f.id // "") | tostring) == "" then .n += 1 | .out += [$f + {id: ("L-" + (.n | pad4))}]
      else .out += [$f] end)
  | {n, out}' <<<"$EXISTING" 2>/dev/null || echo '')"
if jq -e '(.out | type) == "array"' <<<"$FILLED" >/dev/null 2>&1; then
  EXISTING="$(jq -c '.out' <<<"$FILLED")"; MAXID="$(jq -r '.n' <<<"$FILLED")"
fi

# ── INGEST SANITIZATION (v0.9 Rec 1, audit SEC-1): candidate .learning/.evidence is derived from tool output
#    and review-row text (model/attacker-influenceable) and is later re-injected verbatim into FUTURE prompts.
#    Neutralize prompt-injection directives + strip URLs at the WRITE PATH before anything is stored — a payload
#    arriving via memory retrieval bypasses defenses built for the input boundary. Body normalization first,
#    so a `text`-only candidate is sanitized rather than blanked.
CANDS="$(jq -c "$JQ_BODY"'
  def sanitize:
    ( . // "" )
    | gsub("(?i)https?://\\S+"; "[link removed]")
    | gsub("(?i)\\b(ignore|disregard|forget)\\b[^.\n]{0,40}\\b(previous|prior|above|earlier|all)\\b[^.\n]{0,24}\\b(instruction|instructions|rule|rules|prompt|context)\\b"; "[neutralized directive]")
    | gsub("(?i)\\bsystem prompt\\b"; "[neutralized]")
    | gsub("(?i)\\byou are now\\b"; "[neutralized]")
    | gsub("(?i)\\bnew instructions?\\b *:"; "[neutralized]") ;
  [ .[] | select(type == "object") | (body) as $b | del(.text, .lesson)
    | .learning = ($b | sanitize) | .evidence = ((if (.evidence | type) == "string" then .evidence else "" end) | sanitize) ]
' <<<"$CANDS" 2>/dev/null || echo '[]')"

[ -n "$PROJECT" ] || PROJECT="$(jq -r 'map(.project // empty) | (first // "unknown")' <<<"$EXISTING" 2>/dev/null || echo unknown)"

# Service-name tokens never belong in a trigger (07 §8.2): every entry of a party-ms store is "about party",
# so the token only inflates Jaccard between unrelated lessons. From the project tag, the repo dir name and
# topology.json.service: a single-token stem ("party" of party-ms) plus the joined forms ("partyms"). A
# multi-token stem (payment-gateway-ms) drops only its joined forms — "payment" alone is a real keyword.
SVC_NAMES="$(printf '%s\n' "$PROJECT" "$(basename "$PROJECT_DIR")" "$(jq -r '.service // empty' "$DIR/topology.json" 2>/dev/null)")"
SVC_TOK="$(jq -Rsc '
  [ split("\n")[] | ascii_downcase | select(length > 0 and . != "unknown")
    | [scan("[a-z0-9]+")] as $t | ($t | map(select(. != "ms" and . != "service" and . != "svc"))) as $s
    | (if ($s | length) == 1 then $s else [] end) + [($s | join("")), ($t | join(""))] ]
  | flatten | map(select(length > 1)) | unique' <<<"$SVC_NAMES" 2>/dev/null || echo '[]')"

# Shared token rules (jq), used by the gate, the merge and the new-entry writer.
#  - tok: lowercase, [a-z0-9+_] runs, VERSION tokens collapsed to vN (LRN-10: v42/v43 are one lesson; other
#    digits are KEPT, so SQLSTATE 25006 and 40001 stay distinct).
#  - trig: tok minus stopwords, `ms` and service-name tokens, de-duplicated in the order given.
#  - normfull: trig sorted, joined "|" (exact-key fast path); normcap: the first 5 of trig, sorted (what is stored).
#  - fz: the fuzzy token set = trigger tokens ∪ the first 8 distinct content tokens of the learning.
JQ_TOK='
  def tok: ascii_downcase | gsub("(?<a>[^a-z0-9]|^)v[0-9]+(__[a-z0-9_]*)?"; .a + "vN") | [scan("[a-z0-9+_]+")];
  def uniq_ordered: reduce .[] as $x ([]; if index([$x]) then . else . + [$x] end);
  def stopw: ["the","and","for","with","into","from","this","that","when","then","than","are","was","were","use","using","via","not","all","any","its","but","can","has","have","does","did","per","each","also","only","must","should","will","a","an","of","to","in","on","at","by","or","is","be","it","as","if","no","so","ms"];
  def trig($svc): ((. // "") | tostring | tok) | map(select(. as $w | (stopw | index([$w])) == null and ($svc | index([$w])) == null)) | uniq_ordered;
  def normfull($svc): trig($svc) | sort | join("|");
  def normcap($svc): trig($svc) | .[0:5] | sort | join("|");
  def ltok: ((. // "") | tostring | tok) | map(select((length >= 3 or test("^[0-9]+$")) and (. as $w | (stopw | index([$w])) == null))) | uniq_ordered | .[0:8];
  def fz($svc): ((.trigger | trig($svc)) + (.learning | ltok)) | unique;
  def nums: map(select(test("^[0-9]{3,}$")));
  def jac($a; $b): ($b | map({(.): true}) | add // {}) as $bm
    | ([ $a[] | select($bm[.]) ] | length) as $i
    | (($a | length) + ($b | length) - $i) as $u | (if $u == 0 then 0 else $i / $u end);
'

# ── GATE (07 §8.2): a learning must be one real sentence — ≥20 chars and not a copy of its evidence. Then the
#    v0.7 QUALITY GATE score (Issue 7): a learning earns its place on 3 axes (~0.33 each); <0.4 is rejected:
#      specificity  — names a concrete type/method/annotation or a code span (not "be careful with X")
#      evidence     — a real file:line / *.java / *.sql / Test reference (not "no evidence")
#      triggerable  — ≥2 normalized trigger tokens so it can actually fire on a future match
#    Rejects are appended to state/<sid>.rejected.jsonl with the reason, so a drop is auditable.
QSCORED="$(jq -c --argjson svc "$SVC_TOK" "$JQ_TOK"'
  def qscore:
      (if ((.learning // "")  | test("`|@[A-Za-z]|[A-Z][a-z]+[A-Z]")) then 0.34 else 0 end)
    + (if (((.evidence // "") != "") and ((.evidence // "") != "no evidence")
           and ((.evidence // "") | test(":[0-9]|\\.java|\\.sql|Test"))) then 0.33 else 0 end)
    + (if ((.trigger | trig($svc) | length) >= 2) then 0.33 else 0 end);
  [ .[] | . + { _why: (
        if ((.learning | length) < 20) then "learning-under-20-chars"
        elif ((.learning | ascii_downcase) == ((.evidence // "") | ascii_downcase)) then "learning-equals-evidence"
        elif (qscore < 0.4) then "quality-below-0.4"
        else null end) } ]
' <<<"$CANDS" 2>/dev/null || echo '[]')"
REJECTED="$(jq '[ .[] | select(._why != null) ] | length' <<<"$QSCORED" 2>/dev/null || echo 0)"
if [ "${REJECTED:-0}" -gt 0 ]; then
  mkdir -p "$DIR/state" 2>/dev/null || true
  jq -c --arg ts "$TS" '.[] | select(._why != null) | (. + {rejected_reason: ._why, rejected_at: $ts}) | del(._why)' <<<"$QSCORED" \
    >> "$DIR/state/${SID:-nosession}.rejected.jsonl" 2>/dev/null || true
fi
CANDS="$(jq -c '[ .[] | select(._why == null) | del(._why) ]' <<<"$QSCORED" 2>/dev/null || echo '[]')"

# ── MERGE (07 §8.2, D6): exact key first (category + normalized trigger — the fast path), then FUZZY: same
#    category, not superseded, Jaccard(trigger ∪ top-8 learning tokens) ≥ 0.5 → merge into the best match
#    (first on a tie). Exact dedup alone never matched on the real stores: the learner words the same trigger
#    differently every task. Guards: a candidate that declares `supersedes` never fuzzy-merges (it is a
#    refinement, MEM-3), and two sets carrying different numeric codes (SQLSTATE 25006 vs 40001) never merge.
#    A merge bumps hits, confidence (+0.05, ≤1), ts, and folds the evidence in (distinct, ≤3, "; "-joined).
STATE="$(jq -n --argjson existing "$EXISTING" --argjson cands "$CANDS" --arg ts "$TS" --arg project "$PROJECT" \
  --argjson injected "$INJ_IDS" --argjson svc "$SVC_TOK" --argjson maxid "${MAXID:-0}" "$JQ_TOK"'
  def keyf($e): (($e.category // "note")) + "\u0000" + ($e.trigger | normfull($svc));
  def lpad4($n): ($n|tostring) as $s | (if (4 - ($s|length)) > 0 then ("0" * (4 - ($s|length))) else "" end) + $s;
  def evmerge($old; $new): ($old // "" | tostring | split("; ") | map(select(length > 0))) as $o
    | if ($new == null or $new == "" or $new == "no evidence" or ($o | index([$new])) or ($o | length) >= 3)
      then ($old // $new // "no evidence") else ($o + [$new] | join("; ")) end;

  reduce ($cands[]) as $c (
      { arr: [ $existing[] | . + {_k: keyf(.), _f: fz($svc)} ], next: ($maxid + 1),
        added: 0, merged: 0, fuzzy: 0, recurred: 0, applied: 0 };
      ( ($c.category // "note") ) as $cat
      | ( [ keyf($c), ($cat + "\u0000" + ($c.trigger | normcap($svc))) ] ) as $ks
      | ( $c | fz($svc) ) as $cf
      | ( [ .arr | to_entries[] | select(.value._k as $k | $ks | index([$k])) | .key ] | first ) as $exact
      | ( if ($exact != null or $c.supersedes) then null
          else ( [ .arr | to_entries[]
                   | select((.value.category // "note") == $cat and ((.value.status // "") != "superseded"))
                   | select(((.value._f | nums) as $a | ($cf | nums) as $b
                             | (($a | length) == 0 or ($b | length) == 0 or $a == $b)))
                   | {key, j: jac($cf; .value._f)} | select(.j >= 0.5) ]
                 | sort_by(-.j, .key) | first | .key ) end ) as $fuzzy
      | ( $exact // $fuzzy ) as $idx
      | if ($idx == null) then
          .arr += [ ( {
            id: ("L-" + lpad4(.next)),
            ts: $ts, project: $project, phase: "learn",
            category: $cat,
            trigger: ($c.trigger | normcap($svc)),
            learning: $c.learning,
            evidence: (if ($c.evidence // "") == "" then "no evidence" else $c.evidence end),
            confidence: ($c.confidence // 0.6),
            hits: 1, recurrence: 0
          }
          # scope=fleet is kept on the entry; the FLEET step below copies it to the hub (07 §8.2 "Fleet").
          + (if (($c.scope // "") | IN("service", "fleet")) then { scope: $c.scope } else {} end)
          # v0.7: a candidate may declare it refines an earlier learning (mattpocock Learning Records).
          + (if ($c.supersedes) then { supersedes: $c.supersedes, status: "refines" } else {} end)
          # The rule-file mapping reads the trigger BEFORE the service-name drop: in auth-ms, "auth" is a
          # service token yet still names security/spring-security.md. trigger_src = the stored trigger plus
          # the dropped service tokens (nothing else), kept only when the drop removed one.
          + ((($c.trigger | trig([])) - ($c.trigger | trig($svc))) as $drop | if $drop != []
              then { trigger_src: ((($c.trigger | normcap($svc)) | split("|")) + $drop | join("|")) } else {} end) )
          | . + {_k: keyf(.), _f: fz($svc)} ]
          | .next += 1 | .added += 1
        else
          .arr[$idx].hits = ((.arr[$idx].hits // 1) + 1)
          | .arr[$idx].confidence = ([ ((.arr[$idx].confidence // 0.5) + 0.05), 1.0 ] | min)
          | .arr[$idx].ts = $ts
          | .arr[$idx].evidence = evmerge(.arr[$idx].evidence; $c.evidence)
          # a fleet candidate that folds into a local entry makes that entry fleet (copied to the hub below)
          | (if (($c.scope // "") == "fleet") then .arr[$idx].scope = "fleet" else . end)
          | (if ($exact == null) then .fuzzy += 1 else . end)
          # v0.7 EFFECTIVENESS (Issue 7): a pitfall already PROMOTED into a rule that resurfaces as a fresh
          # candidate means the rule did not stop it — the negative RL signal. Count it on the entry + report.
          | ( if ((.arr[$idx].promoted // false) and ($cat == "pitfall"))
              then .arr[$idx].recurrence = ((.arr[$idx].recurrence // 0) + 1) | .recurred += 1
              else . end )
          # v0.8 WS-6 (close the loop): a learning INJECTED at SessionStart that resurfaced this task WAS
          # applied — stamp it. .applied is the positive reward the scoreboard reads (was read, never written).
          # Bind the id BEFORE the `$injected |` pipe — inside that pipe `.` is $injected, so `.arr` would
          # index the array with a string ("Cannot index array with string arr").
          | ( (.arr[$idx].id) as $eid
              | if (($injected | index($eid)) != null)
                then .arr[$idx].applied = ((.arr[$idx].applied // 0) + 1) | .applied += 1
                else . end )
          | .merged += 1
        end
    )
  | {arr: [ .arr[] | del(._k, ._f) ], added, merged, fuzzy, recurred, applied}
')"

ADDED="$(jq -r '.added' <<<"$STATE")"
MERGED="$(jq -r '.merged' <<<"$STATE")"
FUZZY="$(jq -r '.fuzzy' <<<"$STATE")"
RECURRED="$(jq -r '.recurred' <<<"$STATE")"
APPLIED="$(jq -r '.applied' <<<"$STATE")"
ARR="$(jq -c '.arr' <<<"$STATE" 2>/dev/null || true)"
# A failed merge stage must not reach the rule-file regeneration or the write below (both would act on nothing).
jq -e 'type == "array"' <<<"$ARR" >/dev/null 2>&1 \
  || { echo '{"added":0,"merged":0,"promoted":0,"dropped":0,"skipped":"merge-failed"}'; exit 0; }

# ── SUPERSEDE (v0.9 Rec 1, audit MEM-3): a candidate that declared supersedes:<id> was stored above with
#    status:"refines"; now deterministically mark the OLD entry status:"superseded" (newest-fact wins — a
#    plain set operation, no LLM freshness judgment). Superseded entries are excluded from injection + from
#    the regenerated rule-file blocks below, resolving the contradiction to the refining entry.
ARR="$(jq -c '
  ( [ .[] | select(.supersedes != null) | .supersedes ] | flatten ) as $sup
  | map(.id as $eid | if (($eid != null) and (($sup | index($eid)) != null)) then (.status = "superseded") else . end)
' <<<"$ARR" 2>/dev/null || echo "$ARR")"

# ── PROMOTE + REGENERATE: mark qualifying pitfalls promoted, then REBUILD each rule file's auto-promoted
#    block from the CURRENT promoted+live set (replaces the old append-only >> so a superseded/retired
#    pitfall's line DISAPPEARS instead of lingering forever). trigger→file via the static table below.
promote_target() { # $1 = trigger → echoes rule-file relpath or empty
  local t="$1"
  case "$t" in
    *jpa*|*entity*|*hibernate*|*repository*|*n+1*) echo "framework/jpa.md" ;;
    *webflux*|*reactive*|*mono*|*flux*|*r2dbc*)    echo "framework/webflux.md" ;;
    *consumer*)                                    echo "framework/kafka-consumer.md" ;;
    *producer*|*kafka*)                            echo "framework/kafka-producer.md" ;;
    *rabbitmq*|*amqp*)                             echo "framework/rabbitmq.md" ;;
    *nats*)                                        echo "framework/nats.md" ;;
    *redis*|*cache*|*cacheable*)                   echo "framework/redis.md" ;;
    *security*|*auth*|*jwt*|*csrf*)                echo "security/spring-security.md" ;;
    *migration*|*flyway*|*ddl*)                    echo "framework/migration-safety.md" ;;
    *index*|*query*|*slow*)                        echo "performance/indexing.md" ;;
    *pool*|*connection*|*hikari*)                  echo "performance/connection-pool.md" ;;
    *test*|*junit*|*mockito*|*wiremock*|*testcontainers*) echo "testing/junit5.md" ;;
    *controller*|*mvc*|*dto*|*validation*)         echo "framework/spring-mvc.md" ;;
    *) echo "" ;;
  esac
}

# 1) MARK: promote a qualifying pitfall (hits>=5, conf>=0.85, not superseded, not already promoted) ONLY when
#    its trigger maps to an EXISTING rule file — never guess a file. Numeric criteria in jq; the trigger→file
#    + file-existence guard needs promote_target + the filesystem, so it is applied in bash (as before).
PROMOTED_IDS=(); UNMAPPED=0
while IFS=$'\t' read -r id trigger; do
  [ -n "$id" ] || continue
  # LRN-1(b): a pitfall that EARNED promotion but maps to no rule file, or to a file this project does not
  # have, was dropped here without a trace — indistinguishable in the receipt from "nothing qualified".
  # Count it. An unmapped promotion is a coverage gap in the rule corpus, and the receipt is where it shows.
  rel="$(promote_target "$trigger")"
  if [ -z "$rel" ] || [ ! -f "$RULES_DIR/$rel" ]; then UNMAPPED=$((UNMAPPED+1)); continue; fi
  PROMOTED_IDS+=("$id")
done < <(jq -r '.[] | select(.category=="pitfall" and ((.hits//0)>=5) and ((.confidence//0)>=0.85) and ((.promoted//false)|not) and ((.status//"")!="superseded")) | [.id,(.trigger_src // .trigger)] | @tsv' <<<"$ARR")
PROMOTED_COUNT="${#PROMOTED_IDS[@]}"
if [ "$PROMOTED_COUNT" -gt 0 ]; then
  IDS_JSON="$(printf '%s\n' "${PROMOTED_IDS[@]}" | jq -R . | jq -s '.')"
  ARR="$(jq -c --argjson ids "$IDS_JSON" 'map(.id as $eid | if (($eid != null) and (($ids | index($eid)) != null)) then .promoted = true else . end)' <<<"$ARR")"
fi

# 2) REGENERATE each rule file's auto-promoted block from the CURRENT promoted+live set. Strip the block from
#    EVERY rule file first (clean slate → a file whose only pitfall was superseded/retired ends with NO block),
#    then rebuild from the live set. This removes the old append-only staleness (MEM-3).
header="## Learned pitfalls (auto-promoted from learnings.jsonl — edit via the learner, not by hand)"
if [ -d "$RULES_DIR" ]; then
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    grep -qF "$header" "$file" 2>/dev/null || continue
    awk -v h="$header" 'index($0,h){f=1} !f{print}' "$file" > "$file.regen.$$" 2>/dev/null \
      && mv -f "$file.regen.$$" "$file" 2>/dev/null || rm -f "$file.regen.$$" 2>/dev/null
  done < <(find "$RULES_DIR" -name '*.md' 2>/dev/null)
  MAP="$(mktemp)"
  jq -r '.[] | select((.promoted//false) and ((.status//"")!="superseded")) | [(.trigger_src // .trigger),.trigger,.learning,.ts,.evidence] | @tsv' <<<"$ARR" > "$MAP" 2>/dev/null || true
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    file="$RULES_DIR/$rel"; [ -f "$file" ] || continue   # never create a stray rule file
    { printf '\n%s\n' "$header"
      while IFS=$'\t' read -r route trigger learning ts evidence; do
        [ -n "$route" ] || continue
        [ "$(promote_target "$route")" = "$rel" ] || continue
        printf -- '- %s <!-- trigger: %s · promoted: %s · evidence: %s -->\n' "$learning" "$trigger" "$ts" "$evidence"
      done < "$MAP"
    } >> "$file" 2>/dev/null
  done < <(while IFS=$'\t' read -r route _rest; do [ -n "$route" ] && promote_target "$route"; done < "$MAP" | sort -u)
  rm -f "$MAP" 2>/dev/null
fi

# ── PRUNE + RETIRE (v0.9 Rec 1, audit MEM-2/MEM-4): drop decayed noise AND retire even a reinforced entry once
#    it goes DORMANT (untouched >180d — .ts is bumped on every merge/recurrence/apply, so dormant = it stopped
#    resurfacing), so the store cannot grow without bound. Also RESET a promoted pitfall's recurrence after it
#    stops recurring (untouched >60d) so it is no longer re-injected + 2.5x-boosted forever. A promoted+live
#    entry is never retired. A date-only .ts (aml-service's hand-written v0.11 entries: "2026-07-23") is read as that
#    day's midnight; fromdateiso8601 rejects it, and the age used to fall back to the epoch — instant retirement.
BEFORE="$(jq 'length' <<<"$ARR")"
ARR="$(jq -c --argjson now "$NOW" '
  [ .[]
    | ( ($now - ((.ts // "1970-01-01T00:00:00Z") | tostring | (if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") then . + "T00:00:00Z" else . end) | fromdateiso8601? // 0)) / 86400 ) as $age
    | (if ((.promoted // false) and ((.recurrence // 0) > 0) and ($age > 60)) then .recurrence = 0 else . end)
    | select(
        (((.promoted // false)) and (((.status // "") != "superseded")))
        or ( ($age <= 180) and ( ((.hits//1) >= 2) or ((.confidence//0) >= 0.25) or ($age <= 90) ) )
      )
  ]' <<<"$ARR")"
# LRN-7: the TTL alone does not bound the store. Every surviving predicate is satisfiable indefinitely —
# a promoted entry never expires, and anything touched in the last 90 days is kept unconditionally — so a
# busy repo grows without limit (payment-gateway-ms is at 360 entries and climbing, party-ms at 280).
# Add a hard cap by score, applied AFTER the TTL so age still wins first. Promoted entries are exempt:
# they are the audit trail for a rule that already shipped.
ARR="$(jq -c --argjson now "$NOW" --argjson cap 400 '
  if (length <= $cap) then .
  else
    ( [ .[] | select((.promoted // false)) ] ) as $keep
    | ( [ .[] | select((.promoted // false) | not)
          | . + { _r: ( (.confidence // 0.5) * (((.hits // 1) | if . < 1 then 1 else . end))
                        / (1 + ((($now - ((.ts // "1970-01-01T00:00:00Z") | tostring | (if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") then . + "T00:00:00Z" else . end) | fromdateiso8601? // 0)) / 86400) / 30)) ) } ]
        | sort_by(-._r) | .[0:(if ($cap - ($keep | length)) > 0 then ($cap - ($keep | length)) else 0 end)]
        | map(del(._r)) ) as $rest
    | $keep + $rest
  end' <<<"$ARR")"
AFTER="$(jq 'length' <<<"$ARR")"
DROPPED=$(( BEFORE - AFTER ))

# ── Atomic write (never leave a half-written store). A failed jq stage leaves ARR empty or non-JSON; writing
#    that would truncate the store, so a non-array ARR aborts before the write (fail-open, store untouched).
if ! jq -e 'type == "array"' <<<"$ARR" >/dev/null 2>&1; then
  echo '{"added":0,"merged":0,"promoted":0,"dropped":0,"skipped":"merge-failed"}'; exit 0
fi
TMP="$LEARNINGS.tmp.$$"
jq -c '.[]' <<<"$ARR" > "$TMP" 2>/dev/null && mv -f "$TMP" "$LEARNINGS" || { rm -f "$TMP" 2>/dev/null; }

REPORT="$(jq -nc --argjson a "$ADDED" --argjson m "$MERGED" --argjson p "$PROMOTED_COUNT" --argjson d "$DROPPED" \
  --argjson r "${REJECTED:-0}" --argjson rc "${RECURRED:-0}" --argjson ap "${APPLIED:-0}" \
  --argjson um "${UNMAPPED:-0}" --argjson fz "${FUZZY:-0}" --argjson rp "${REPAIRED:-0}" \
  '{added:$a, merged:$m, fuzzy:$fz, promoted:$p, dropped:$d, rejected:$r, repaired:$rp, recurred:$rc, applied:$ap, unmapped:$um}')"

# ── FLEET (07 §8.2, M6): a live scope=fleet entry of a microservice plane is copied into the hub's
#    fleet-learnings.jsonl under the hub's own lock, with provenance sources:[{service,id}] (a name and a local
#    id — never a path: the file is on the hub's commit list). Upsert from the FINAL store, so a fleet candidate
#    that folded into an existing L-#### still lands with that id, and a re-run is a no-op. The same lesson
#    from a second service (same category, Jaccard ≥0.5 on trigger ∪ learning tokens) gains a source instead
#    of a row. promoted/recurrence/applied stay local (a rule promoted in one repo does not exist in another).
#    No hub (mono, no topology.hub/CLAUDEHUT_HUB, or the hub dir absent) → nothing is written, no dir created.
FLEET_DIR=""
if [ "$(jq -r '.mode // empty' "$DIR/topology.json" 2>/dev/null)" = microservice ]; then
  _hb="$(jq -r '.hub // empty | strings' "$DIR/topology.json" 2>/dev/null)" || _hb=""
  [ -z "${CLAUDEHUT_HUB:-}" ] || _hb="$CLAUDEHUT_HUB"
  if [ -n "$_hb" ]; then
    case "$_hb" in /*) : ;; *) _hb="$PROJECT_DIR/$_hb" ;; esac
    if [ -d "$_hb/.claude/claudehut/hub" ]; then FLEET_DIR="$_hb/.claude/claudehut/hub"
    elif [ -f "$_hb/hub.json" ]; then FLEET_DIR="$_hb"; fi
  fi
fi
if [ -n "$FLEET_DIR" ] && [ -w "$FLEET_DIR" ]; then
  release_lock   # the local store is written; never hold two locks
  FSVC="$(jq -r '.service // empty | strings' "$DIR/topology.json" 2>/dev/null)" || FSVC=""
  [ -n "$FSVC" ] || FSVC="$(basename "$PROJECT_DIR")"
  FLEET="$FLEET_DIR/fleet-learnings.jsonl"; FLOCK="$FLEET.lock"
  # mkdir-lock only (a flock file would persist in the hub repo); steal after 30 s, proceed after 10 s.
  _fstart="$(date -u +%s)"; _fheld=0
  while :; do
    if mkdir "$FLOCK" 2>/dev/null; then _fheld=1; break; fi
    [ -e "$FLOCK" ] && [ ! -d "$FLOCK" ] && { rm -f "$FLOCK" 2>/dev/null; continue; }
    _fnow="$(date -u +%s)"; _flm="$(_lock_mtime "$FLOCK")"
    if [ "${_flm:-0}" -gt 0 ] && [ "$(( _fnow - _flm ))" -ge 30 ]; then rm -rf "$FLOCK" 2>/dev/null; continue; fi
    [ "$(( _fnow - _fstart ))" -ge 10 ] && break
    sleep 0.02 2>/dev/null || true
  done
  [ "$_fheld" = 1 ] && trap 'rm -rf "$FLOCK" 2>/dev/null' EXIT INT TERM
  FEX='[]'; [ -f "$FLEET" ] && FEX="$(jq -R 'fromjson? // empty' "$FLEET" 2>/dev/null | jq -s '.' 2>/dev/null || echo '[]')"
  FOUT="$(jq -c -n --argjson fex "$FEX" --argjson arr "$ARR" --arg svc "$FSVC" "$JQ_TOK"'
    def lpad4($n): ($n|tostring) as $s | (if (4 - ($s|length)) > 0 then ("0" * (4 - ($s|length))) else "" end) + $s;
    def ffz: ((.trigger | trig([])) + (.learning | ltok)) | unique;
    def issrc($i): any((.sources // [])[]; .service == $svc and .id == $i);
    reduce ($arr[] | select((.scope // "") == "fleet" and ((.learning // "") != ""))) as $e (
      { f: $fex, n: ([ $fex[] | (.id // "") | tostring | capture("F-(?<n>[0-9]+)")? | .n | tonumber ] | max // 0),
        c: 0 };
      ( $e | ffz ) as $ef | (($e.status // "") == "superseded") as $sup
      | ( [ .f | to_entries[] | select(.value | issrc($e.id)) | .key ] | first ) as $own
      | if $own != null then
          ( .f[$own] ) as $o
          | ( if $sup then
                (if (($o.sources // []) | length) <= 1 then $o + {status: "superseded"}
                 else $o + {sources: [ $o.sources[] | select((.service == $svc and .id == $e.id) | not) ]} end)
              elif (($o.sources[0].service == $svc) and ($o.sources[0].id == $e.id)) then
                $o + {trigger: $e.trigger, learning: $e.learning, evidence: $e.evidence,
                      confidence: ([($o.confidence // 0), ($e.confidence // 0)] | max),
                      hits: ([($o.hits // 1), ($e.hits // 1)] | max), ts: ([($o.ts // ""), ($e.ts // "")] | max)}
              else $o end ) as $u
          | if $u != $o then .f[$own] = $u | .c += 1 else . end
        elif $sup then .
        else
          ( [ .f | to_entries[]
              | select((.value.category // "note") == ($e.category // "note") and ((.value.status // "") != "superseded"))
              | {key, j: jac($ef; (.value | ffz))} | select(.j >= 0.5) ] | sort_by(-.j, .key) | first | .key ) as $fz
          | if $fz != null then
              .f[$fz].sources = ((.f[$fz].sources // []) + [{service: $svc, id: $e.id}])
              | .f[$fz].hits = ((.f[$fz].hits // 1) + 1)
              | .f[$fz].confidence = ([(.f[$fz].confidence // 0), ($e.confidence // 0)] | max)
              | .c += 1
            else
              .n += 1
              | .f += [ {id: ("F-" + lpad4(.n)), ts: $e.ts, category: ($e.category // "note"), trigger: $e.trigger,
                         learning: $e.learning, evidence: $e.evidence, confidence: ($e.confidence // 0.6),
                         hits: ($e.hits // 1), scope: "fleet", sources: [{service: $svc, id: $e.id}]} ]
              | .c += 1
            end
        end )
    | {c, f: (.f | if length > 400 then sort_by(-((.confidence // 0.5) * (.hits // 1))) | .[0:400] else . end)}
  ' 2>/dev/null || true)"
  FCOUNT=0
  if jq -e '(.f | type) == "array"' <<<"$FOUT" >/dev/null 2>&1; then
    FCOUNT="$(jq -r '.c' <<<"$FOUT")"
    if [ "${FCOUNT:-0}" -gt 0 ]; then
      jq -c '.f[]' <<<"$FOUT" > "$FLEET.tmp.$$" 2>/dev/null && mv -f "$FLEET.tmp.$$" "$FLEET" 2>/dev/null \
        || { rm -f "$FLEET.tmp.$$" 2>/dev/null; FCOUNT=0; }
    fi
  fi
  [ "$_fheld" = 1 ] && rm -rf "$FLOCK" 2>/dev/null
  REPORT="$(jq -c --argjson fl "${FCOUNT:-0}" '. + {fleet: $fl}' <<<"$REPORT")"
fi

# WS-6: per-session learn-receipt — proves a Learn pass actually RAN this session (v0.11's Stop gate checked its
# freshness; that gate is gone in v0.12, and capture-learnings still reads the receipt before set-phase learn).
if [ -n "$SID" ]; then
  RC="$DIR/state/$SID.learn-receipt.json"
  mkdir -p "$DIR/state" 2>/dev/null || true
  jq -nc --arg ts "$TS" --argjson rep "$REPORT" '{ts:$ts} + $rep' > "$RC.tmp.$$" 2>/dev/null \
    && mv -f "$RC.tmp.$$" "$RC" 2>/dev/null || rm -f "$RC.tmp.$$" 2>/dev/null
fi

# 07 §8.1: MEMORY.md's generated block carries the topic counts, so refresh it after the store changed. Only a
# file that already has the markers — migrating a legacy file is maintain.sh's job, not the Learn phase's.
# Silent and fail-open: the JSON report is the only output.
case "$0" in */*) _here="${0%/*}" ;; *) _here="." ;; esac
if [ -f "$DIR/MEMORY.md" ] && [ -f "$_here/index/memory.py" ] && command -v python3 >/dev/null 2>&1; then
  python3 "$_here/index/memory.py" --plane "$DIR" --no-migrate >/dev/null 2>&1 || true
fi

printf '%s\n' "$REPORT"
