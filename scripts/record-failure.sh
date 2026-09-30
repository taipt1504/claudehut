#!/usr/bin/env bash
# PostToolUseFailure hook (matcher: Bash) — failure SIGNAL capture (audit C.3).
#
# Stages failed Bash commands (build/test errors) to a SESSION-SCOPED, ephemeral file so the
# Learn phase has real failure signal to curate. It does NOT write the permanent learnings.jsonl
# directly: many Bash failures are intentional (TDD RED runs, expected non-zero exits), so
# auto-promoting them would pollute the curated store. The learner reads this staging file and
# decides what is a genuine, reusable lesson. Non-blocking (the tool already failed); always exit 0.
#
# Staging file: .claude/claudehut/state/<sid>.failures.jsonl  (under state/ = gitignored/ephemeral).
case "$0" in */*) _d="${0%/*}" ;; *) _d="." ;; esac
. "$_d/lib/hook-common.sh" 2>/dev/null || exit 0
hc_init
hc_plane_or_exit          # no plane → exit 0 and create nothing (K7)
in="$HC_IN"
trap - ERR                # this body predates the lib and relies on non-errexit semantics (a grep miss is
                          # a normal negative); the EXIT trap still guarantees exit 0 and a silent stdout

# W0-B (v0.11): every field this script reads except .tool_input.command comes back EMPTY in production —
# measured 682/682 records with empty type+exit+stderr across the real repos. The field paths below were
# guessed, and guessing a second set would repeat the bug. So: with CLAUDEHUT_DEBUG_PAYLOAD=1, append the
# RAW payload before any field is read or any early-exit fires, so the real key names can be read off a
# real event. Off by default; costs nothing when unset. Deliberately not session-scoped — .session_id is
# itself one of the guesses, and a wrong guess there would silently produce no file at all.
if [ "${CLAUDEHUT_DEBUG_PAYLOAD:-}" = "1" ]; then
  _dbg="$PROJECT_DIR/.claude/claudehut/state"
  mkdir -p "$_dbg" 2>/dev/null \
    && printf '%s\n' "$in" >> "$_dbg/payload-debug.PostToolUseFailure.jsonl" 2>/dev/null || true
fi

sid="$HC_SID"   # validated by hc_safe_id (empty when unsafe), so a '../' session_id cannot leave state/
tool="$(jq -r '.tool_name // empty' <<<"$in" 2>/dev/null || true)"
[ -n "$sid" ] && [ "$tool" = "Bash" ] || exit 0

cmd="$(jq -r '.tool_input.command // empty' <<<"$in" 2>/dev/null || true)"
# W0-B (v0.11) — field paths taken from a REAL captured payload, not from the docs (which document no
# input schema for this event) and not from inference. A genuine `ls /no/such/dir` failure sends:
#   session_id transcript_path cwd prompt_id permission_mode effort hook_event_name tool_name
#   tool_input tool_use_id error is_interrupt duration_ms
# There is no `tool_error` object and no `tool_response`. The previous paths — .tool_error.exit_code /
# .tool_error.type / .tool_error.stderr — could never match anything, which is why 682 of 682 production
# records carried an empty exit, type and stderr while only .tool_input.command was populated.
#
# `error` packs the exit code and the message into one string:
#   "Exit code 1\nls: /no/such/dir/xyz: No such file or directory"
raw_err="$(jq -r '.error // empty' <<<"$in" 2>/dev/null || true)"
code="$(printf '%s' "$raw_err" | sed -n '1s/^Exit code \([0-9][0-9]*\).*/\1/p')"
# type distinguishes a user interrupt from a real failure — the two deserve different treatment in Learn,
# since an interrupted command says nothing about the code.
if [ "$(jq -r '.is_interrupt // false' <<<"$in" 2>/dev/null || echo false)" = "true" ]; then
  etype="interrupt"
else
  etype="${raw_err:+error}"
fi
# drop the leading "Exit code N" line — it is already in `exit` — and keep a short tail: enough to
# fingerprint the failure, not a wall of logs.
err="$(printf '%s' "$raw_err" | sed '1{/^Exit code [0-9]/d;}' | tail -c 600)"
[ -n "$cmd" ] || exit 0

DIR="$PROJECT_DIR/.claude/claudehut/state"
mkdir -p "$DIR" 2>/dev/null || exit 0
F="$DIR/$sid.failures.jsonl"

# The hook runs async, so identical failures arrive concurrently: the read-bump-rewrite below and the 20-line
# cap are one critical section. A short mkdir-lock serializes them, with a stale-lock breaker for a killed holder.
# The wait is fail-open and bounded twice, whichever comes first: 200 waits of 0.01 s (~2 s on an idle machine) and
# a 5 s deadline on bash's whole-second SECONDS clock (so 4-5 s of wall time). A loaded scheduler stretches the
# 200 waits, and the deadline keeps the give-up well under the 10 s stale age: a waiter stops before a lock that a
# live holder took at the start of its wait can age into one it would steal as stale.
# Released on every path by the EXIT trap below.
# The staged file is an advisory signal for Learn, so fail-open after the cap is accepted: its worst case is one
# lost .hits bump or record, never a hang.
L="$F.lock"; _held=""; _me="$$.${RANDOM:-0}"
# GNU stat first: on Linux `stat -f` is --file-system, so `-f %m` prints a multi-line report AND fails, and the
# old BSD-first order captured that report — the stale test then never fired (HC2-1). Non-numeric → 0 (no steal).
_lm() { local m; m="$(stat -c %Y "$1" 2>/dev/null)" || m="$(stat -f %m "$1" 2>/dev/null)" || m=0
        case "$m" in ''|*[!0-9]*) m=0 ;; esac; printf '%s' "$m"; }
_old() { local m; m="$(_lm "$1")"; [ "${m:-0}" -gt 0 ] && [ $(( $(date +%s) - m )) -ge 10 ]; }
# Every REMOVAL of the lock runs under a second, short-lived token dir ($L.steal) and re-checks, under it, that the
# lock is still the one it means to remove. A steal decided from one earlier observation is otherwise
# check-then-act: another waiter could break the stale lock and a new writer take a fresh one before this `rmdir`
# ran, which then deleted that fresh lock (V3-C1). For a STEAL the age re-check under the token is the real guard —
# a lock taken in the meantime is fresh, so it is left alone. The nonce is only a secondary check there: it is read
# after the stale observation, so it names whichever lock is present by then, not the one that was judged stale.
# For a RELEASE the nonce is the whole guard: a holder paused past the stale age, whose lock was stolen and retaken,
# finds another owner's nonce and removes nothing.
_rm_lock() { # $1 = owner nonce the caller expects  $2 = steal|release
  local k
  for k in 1 2 3 4 5 6 7 8 9 10; do
    mkdir "$L.steal" 2>/dev/null && break
    _old "$L.steal" && rmdir "$L.steal" 2>/dev/null   # a token left by a killed waiter
    [ "$k" = 10 ] && return 0
    sleep 0.01 2>/dev/null || true
  done
  if [ "$(cat "$L/o" 2>/dev/null)" = "$1" ] && { [ "$2" = release ] || _old "$L"; }; then rm -rf "$L" 2>/dev/null; fi
  rmdir "$L.steal" 2>/dev/null
}
_dl=$((SECONDS + 5))
for _i in $(seq 1 200); do
  [ "$SECONDS" -lt "$_dl" ] || break
  if mkdir "$L" 2>/dev/null; then _held=1; printf '%s' "$_me" > "$L/o" 2>/dev/null; break; fi
  if _old "$L"; then _rm_lock "$(cat "$L/o" 2>/dev/null)" steal; continue; fi
  sleep 0.01 2>/dev/null || true
done
trap '_rc=$?; [ -z "$_held" ] || _rm_lock "$_me" release; (exit "$_rc"); hc_exit' EXIT

# dedup: an immediately-repeated identical failure BUMPS the previous record's hit count instead of being
# dropped. Dropping it was silently fighting the harvest: harvest-candidates.sh calls a signature a pitfall
# only at >=2 occurrences, and the commonest real shape — run the build, it fails, run it again, it fails —
# produced exactly one record and therefore never became a pitfall. Bumping keeps the record count bounded
# AND preserves the recurrence signal.
if [ -f "$F" ]; then
  prev="$(tail -1 "$F" 2>/dev/null | jq -r '"\(.command)\u0000\(.exit)"' 2>/dev/null || true)"
  this="$(printf '%s\000%s' "$cmd" "$code")"
  if [ "$prev" = "$this" ]; then
    bumped="$(tail -1 "$F" 2>/dev/null | jq -c '.hits = ((.hits // 1) + 1)' 2>/dev/null || true)"
    if [ -n "$bumped" ]; then
      tmp="$(mktemp "$DIR/.fail.XXXXXX")" \
        && { sed '$d' "$F"; printf '%s\n' "$bumped"; } > "$tmp" && mv -f "$tmp" "$F" 2>/dev/null || true
    fi
    exit 0
  fi
fi

# W0-B (v0.11): when ALL THREE known error paths come back empty, the schema this script was written
# against is not the schema being sent (measured: 682/682 production records, empty type+exit+stderr).
# Record the payload's top-level KEY NAMES so the next real failure names the right fields by itself,
# without a debug env var having been set in advance. Names only, never values — a payload carries
# command text and environment detail that must not be appended to a staged file. Capped at 200 chars,
# as record-rules-loaded.sh caps its fields. Emitted ONLY on the empty case, so a healthy payload
# produces a byte-identical record and nothing downstream sees a new field.
keys=""
if [ -z "$code" ] && [ -z "$etype" ] && [ -z "$err" ]; then
  keys="$(jq -r 'keys_unsorted | join(",")' <<<"$in" 2>/dev/null || true)"
  keys="${keys:0:200}"
fi

line="$(jq -nc --arg c "$cmd" --arg code "$code" --arg t "$etype" --arg e "$err" --arg k "$keys" \
  '{command:$c, exit:$code, type:$t, stderr:$e}
   + (if $k == "" then {} else {schema_keys:$k} end)' 2>/dev/null || true)"
[ -n "$line" ] && printf '%s\n' "$line" >> "$F"

# cap at the last 20 failures so the staging file can't grow without bound
if [ "$(wc -l < "$F" 2>/dev/null || echo 0)" -gt 20 ]; then
  tmp="$(mktemp "$DIR/.fail.XXXXXX")" && tail -20 "$F" > "$tmp" && mv -f "$tmp" "$F" 2>/dev/null || true
fi
exit 0
