#!/usr/bin/env bash
# Deterministic learnings engine. Called by the capture-learnings skill (which has Bash) AFTER the
# learner agent returns its candidate extractions. Does the work that must NOT be an LLM reasoning task:
# normalize triggers, dedup by category+normalized-trigger, merge (hits++, confidence+0.05, ts=now) or
# append, PROMOTE proven pitfalls into rule files, PRUNE decayed noise. The learner used to do all of
# this by reasoning at xhigh effort — minutes of latency on a 2-line file. Here it is milliseconds and
# exact. See 07 §5 / agents/claudehut-learner.md.
#
# Usage: merge-learnings.sh --candidates PATH [--project NAME] [--ts ISO8601]
#   --candidates PATH   JSONL of candidate learnings from the learner. Each line:
#                       {category, trigger, learning, evidence, confidence?}  (trigger in any form —
#                       normalization is applied here; confidence defaults to 0.6 for a new entry).
#   --project NAME      project tag for new entries (default: existing entries' project, else "unknown")
#   --ts ISO8601        timestamp for merged/new entries (default: now, UTC)
# Emits a one-line JSON report: {added, merged, promoted, dropped}. Never corrupts the store (atomic write);
# fails open (exit 0, empty report) when jq or the candidates file is missing.
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo '{"added":0,"merged":0,"promoted":0,"dropped":0,"skipped":"no-jq"}'; exit 0; }

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$PWD}"
DIR="$PROJECT_DIR/.claude/claudehut"
LEARNINGS="$DIR/learnings.jsonl"
RULES_DIR="$PROJECT_DIR/.claude/rules"

CAND=""; PROJECT=""; TS=""; SID=""; INJECTED=""
while [ $# -gt 0 ]; do
  case "$1" in
    --candidates) CAND="${2:-}"; shift 2 ;;
    --project)    PROJECT="${2:-}"; shift 2 ;;
    --ts)         TS="${2:-}"; shift 2 ;;
    --session)    SID="${2:-}"; shift 2 ;;   # WS-6: write a per-session learn-receipt the Stop gate checks
    --injected)   INJECTED="${2:-}"; shift 2 ;;  # WS-6: ids injected at SessionStart → stamp .applied on resurface
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

[ -n "$CAND" ] && [ -f "$CAND" ] || { echo '{"added":0,"merged":0,"promoted":0,"dropped":0,"skipped":"no-candidates"}'; exit 0; }
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
_lock_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }
_lock_held=""
release_lock() {
  case "$_lock_held" in
    mkdir) rm -rf "$LOCK" 2>/dev/null ;;
    flock) exec 9>&- 2>/dev/null ;;   # closing the fd releases the flock
  esac
  _lock_held=""
}
acquire_lock() {
  # Prefer flock — a REAL blocking wait (deterministic; present on Linux/CI). fd 9 held for the run;
  # released on close/exit. -w 10 caps the wait, then proceeds (fail-open, never wedges).
  if command -v flock >/dev/null 2>&1; then
    if exec 9>"$LOCK.flock" 2>/dev/null && flock -w 10 9 2>/dev/null; then
      _lock_held="flock"; trap 'release_lock' EXIT INT TERM
    fi
    return 0
  fi
  # Fallback (e.g. macOS without flock): atomic mkdir-lock, stale-lock breaker (steal after 30s), bounded by
  # WALL-CLOCK not iteration count (iteration caps bail early on a fast/slow host — the CI MEM-1 failure).
  local start; start="$(date -u +%s)"
  while ! mkdir "$LOCK" 2>/dev/null; do
    local now; now="$(date -u +%s)"
    lm="$(_lock_mtime "$LOCK")"
    # steal ONLY on a real, genuinely old mtime: _lock_mtime falls back to 0 when stat loses a race with
    # the holder's rm, and treating that 0 as "ancient" steals an actively-held lock (same guard as
    # bin/claudehut-state, where it measured 11/25 lost updates under 4-way contention).
    if [ -d "$LOCK" ] && [ "${lm:-0}" -gt 0 ] && [ "$(( now - lm ))" -ge 30 ]; then
      rm -rf "$LOCK" 2>/dev/null; continue          # steal a stale lock (crashed/killed writer)
    fi
    if [ "$(( now - start ))" -ge 10 ]; then return 0; fi   # 10s wall-clock cap → proceed (fail-open)
  done
  _lock_held="mkdir"; trap 'release_lock' EXIT INT TERM
}
acquire_lock

# Load existing store + candidates as JSON arrays (tolerate absent/blank/garbage lines).
EXISTING='[]'; [ -f "$LEARNINGS" ] && EXISTING="$(jq -R 'fromjson? // empty' "$LEARNINGS" 2>/dev/null | jq -s '.' 2>/dev/null || echo '[]')"
CANDS="$(jq -R 'fromjson? // empty' "$CAND" 2>/dev/null | jq -s '.' 2>/dev/null || echo '[]')"

# ── INGEST SANITIZATION (v0.9 Rec 1, audit SEC-1): candidate .learning/.evidence is derived from tool output
#    and review-row text (model/attacker-influenceable) and is later re-injected verbatim into FUTURE prompts.
#    Neutralize prompt-injection directives + strip URLs at the WRITE PATH before anything is stored — a payload
#    arriving via memory retrieval bypasses defenses built for the input boundary.
CANDS="$(jq -c '
  def sanitize:
    ( . // "" )
    | gsub("(?i)https?://\\S+"; "[link removed]")
    | gsub("(?i)\\b(ignore|disregard|forget)\\b[^.\n]{0,40}\\b(previous|prior|above|earlier|all)\\b[^.\n]{0,24}\\b(instruction|instructions|rule|rules|prompt|context)\\b"; "[neutralized directive]")
    | gsub("(?i)\\bsystem prompt\\b"; "[neutralized]")
    | gsub("(?i)\\byou are now\\b"; "[neutralized]")
    | gsub("(?i)\\bnew instructions?\\b *:"; "[neutralized]") ;
  [ .[] | .learning = ((.learning // "") | sanitize) | .evidence = ((.evidence // "") | sanitize) ]
' <<<"$CANDS" 2>/dev/null || echo "$CANDS")"

[ -n "$PROJECT" ] || PROJECT="$(jq -r 'map(.project // empty) | (first // "unknown")' <<<"$EXISTING" 2>/dev/null || echo unknown)"

# ── QUALITY GATE (v0.7, Issue 7): score each candidate, drop low-quality noise BEFORE it enters the store.
#    A learning earns its place on 3 axes (~0.33 each); <0.4 (i.e. fewer than ~2 axes) is rejected:
#      specificity  — names a concrete type/method/annotation or a code span (not "be careful with X")
#      evidence     — a real file:line / *.java / *.sql / Test reference (not "no evidence")
#      triggerable  — ≥2 trigger tokens so it can actually fire on a future match
#    The learner is told "quality over volume"; this makes it deterministic instead of hopeful.
QSCORED="$(jq -c -n --argjson cands "$CANDS" '
  def qscore:
      (if ((.learning // "")  | test("`|@[A-Za-z]|[A-Z][a-z]+[A-Z]")) then 0.34 else 0 end)
    + (if (((.evidence // "") != "") and ((.evidence // "") != "no evidence")
           and ((.evidence // "") | test(":[0-9]|\\.java|\\.sql|Test"))) then 0.33 else 0 end)
    + (if (((.trigger // "") | ascii_downcase | [scan("[a-z0-9+_]+")] | length) >= 2) then 0.33 else 0 end);
  [ $cands[] | . + {_q: qscore} ]
')"
REJECTED="$(jq '[ .[] | select(._q < 0.4) ] | length' <<<"$QSCORED" 2>/dev/null || echo 0)"
CANDS="$(jq -c '[ .[] | select(._q >= 0.4) | del(._q) ]' <<<"$QSCORED" 2>/dev/null || echo "$CANDS")"

# ── MERGE: dedup by (category + normalized trigger); merge or append. Normalization is the same rule
#    the schema documents: lowercase, split on | / space / comma / hyphen, drop empties, sort, rejoin "|".
STATE="$(jq -n --argjson existing "$EXISTING" --argjson cands "$CANDS" --arg ts "$TS" --arg project "$PROJECT" --argjson injected "$INJ_IDS" '
  # LRN-10: collapse VERSION-like tokens before dedup. Two entries in the real store carry the triggers
  # "flyway|free|migration|next|v42" and "...|v43" — the same lesson, one fresh copy per migration forever,
  # because the version number keeps them distinct. Only v<digits> (and Flyway V<digits>__name) collapse:
  # normalising ALL digits would merge genuinely different lessons, such as two about different SQLSTATE
  # codes, which this codebase actually has (25006 vs 40001).
  def norm($t): ($t // "") | ascii_downcase
    | gsub("(?<a>[^a-z0-9]|^)v[0-9]+(__[a-z0-9_]*)?"; .a + "vN")
    | [scan("[a-z0-9+_]+")] | sort | join("|");
  def keyf($e): (($e.category // "note")) + "\u0000" + norm($e.trigger);
  def lpad4($n): ($n|tostring) as $s | (if (4 - ($s|length)) > 0 then ("0" * (4 - ($s|length))) else "" end) + $s;

  ( [ $existing[] | (.id // "") | capture("L-(?<n>[0-9]+)")? | .n | tonumber ] | (max // 0) ) as $maxid
  | reduce ($cands[]) as $c (
      { arr: $existing, next: ($maxid + 1), added: 0, merged: 0, recurred: 0, applied: 0 };
      ( keyf($c) ) as $k
      | ( [ .arr | to_entries[] | select( keyf(.value) == $k ) | .key ] | first ) as $idx
      | if ($idx == null) then
          .arr += [ ( {
            id: ("L-" + lpad4(.next)),
            ts: $ts, project: $project, phase: "learn",
            category: ($c.category // "note"),
            trigger: norm($c.trigger),
            learning: ($c.learning // ""),
            evidence: ($c.evidence // "no evidence"),
            confidence: ($c.confidence // 0.6),
            hits: 1, recurrence: 0
          }
          # v0.7: a candidate may declare it refines an earlier learning (mattpocock Learning Records).
          + (if ($c.supersedes) then { supersedes: $c.supersedes, status: "refines" } else {} end) ) ]
          | .next += 1 | .added += 1
        else
          .arr[$idx].hits = ((.arr[$idx].hits // 1) + 1)
          | .arr[$idx].confidence = ([ ((.arr[$idx].confidence // 0.5) + 0.05), 1.0 ] | min)
          | .arr[$idx].ts = $ts
          # v0.7 EFFECTIVENESS (Issue 7): a pitfall already PROMOTED into a rule that resurfaces as a fresh
          # candidate means the rule did not stop it — the negative RL signal. Count it on the entry + report.
          | ( if ((.arr[$idx].promoted // false) and (($c.category // "note") == "pitfall"))
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
  | {arr, added, merged, recurred, applied}
')"

ADDED="$(jq -r '.added' <<<"$STATE")"
MERGED="$(jq -r '.merged' <<<"$STATE")"
RECURRED="$(jq -r '.recurred' <<<"$STATE")"
APPLIED="$(jq -r '.applied' <<<"$STATE")"
ARR="$(jq -c '.arr' <<<"$STATE")"

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
done < <(jq -r '.[] | select(.category=="pitfall" and ((.hits//0)>=5) and ((.confidence//0)>=0.85) and ((.promoted//false)|not) and ((.status//"")!="superseded")) | [.id,.trigger] | @tsv' <<<"$ARR")
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
  jq -r '.[] | select((.promoted//false) and ((.status//"")!="superseded")) | [.trigger,.learning,.ts,.evidence] | @tsv' <<<"$ARR" > "$MAP" 2>/dev/null || true
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    file="$RULES_DIR/$rel"; [ -f "$file" ] || continue   # never create a stray rule file
    { printf '\n%s\n' "$header"
      while IFS=$'\t' read -r trigger learning ts evidence; do
        [ -n "$trigger" ] || continue
        [ "$(promote_target "$trigger")" = "$rel" ] || continue
        printf -- '- %s <!-- trigger: %s · promoted: %s · evidence: %s -->\n' "$learning" "$trigger" "$ts" "$evidence"
      done < "$MAP"
    } >> "$file" 2>/dev/null
  done < <(while IFS=$'\t' read -r trigger _rest; do [ -n "$trigger" ] && promote_target "$trigger"; done < "$MAP" | sort -u)
  rm -f "$MAP" 2>/dev/null
fi

# ── PRUNE + RETIRE (v0.9 Rec 1, audit MEM-2/MEM-4): drop decayed noise AND retire even a reinforced entry once
#    it goes DORMANT (untouched >180d — .ts is bumped on every merge/recurrence/apply, so dormant = it stopped
#    resurfacing), so the store cannot grow without bound. Also RESET a promoted pitfall's recurrence after it
#    stops recurring (untouched >60d) so it is no longer re-injected + 2.5x-boosted forever. A promoted+live
#    entry is never retired.
BEFORE="$(jq 'length' <<<"$ARR")"
ARR="$(jq -c --argjson now "$NOW" '
  [ .[]
    | ( ($now - ((.ts // "1970-01-01T00:00:00Z") | fromdateiso8601? // 0)) / 86400 ) as $age
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
                        / (1 + ((($now - ((.ts // "1970-01-01T00:00:00Z") | fromdateiso8601? // 0)) / 86400) / 30)) ) } ]
        | sort_by(-._r) | .[0:(if ($cap - ($keep | length)) > 0 then ($cap - ($keep | length)) else 0 end)]
        | map(del(._r)) ) as $rest
    | $keep + $rest
  end' <<<"$ARR")"
AFTER="$(jq 'length' <<<"$ARR")"
DROPPED=$(( BEFORE - AFTER ))

# ── Atomic write (never leave a half-written store).
TMP="$LEARNINGS.tmp.$$"
jq -c '.[]' <<<"$ARR" > "$TMP" 2>/dev/null && mv -f "$TMP" "$LEARNINGS" || { rm -f "$TMP" 2>/dev/null; }

REPORT="$(jq -nc --argjson a "$ADDED" --argjson m "$MERGED" --argjson p "$PROMOTED_COUNT" --argjson d "$DROPPED" \
  --argjson r "${REJECTED:-0}" --argjson rc "${RECURRED:-0}" --argjson ap "${APPLIED:-0}" \
  --argjson um "${UNMAPPED:-0}" \
  '{added:$a, merged:$m, promoted:$p, dropped:$d, rejected:$r, recurred:$rc, applied:$ap, unmapped:$um}')"

# WS-6: per-session learn-receipt — proves a Learn pass actually RAN this session (the Stop gate checks the
# receipt's freshness, replacing the fictional "learnings.jsonl is non-empty" check that any prior line passed).
if [ -n "$SID" ]; then
  RC="$DIR/state/$SID.learn-receipt.json"
  mkdir -p "$DIR/state" 2>/dev/null || true
  jq -nc --arg ts "$TS" --argjson rep "$REPORT" '{ts:$ts} + $rep' > "$RC.tmp.$$" 2>/dev/null \
    && mv -f "$RC.tmp.$$" "$RC" 2>/dev/null || rm -f "$RC.tmp.$$" 2>/dev/null
fi

printf '%s\n' "$REPORT"
