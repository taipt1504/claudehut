#!/usr/bin/env bash
# Prompt-length + provenance lint (v0.8 WS-9, Issue 8: verbose skills/agents).
#
# HONESTLY SOFT: this is a COMMIT-TIME / CI auditor, NOT a runtime gate. Verbosity has no runtime primitive
# (a hook can't measure "is this prompt too long" before the model reads it). So this runs in pre-commit / CI
# to (a) cap each skill/agent body at a per-file budget — catching RE-GROWTH after the WS-9 trim — and
# (b) flag provenance/audit tags (RC-x, Issue-N, EVAL-REPORT, "measured N", audit B.x) that pollute the
# always-loaded hot path (their place is the research docs, not the prompt the agent reads every turn).
#
# Usage:
#   lint-prompt-length.sh              # lint the repo; exit 1 if any file is over budget or carries provenance
#   lint-prompt-length.sh --self-test  # prove the linter discriminates (synthetic over-budget + provenance) — free
#
# Payload measurement (M0 baseline, audit F-7: the lint above never saw the always-loaded hook context).
# Measurement only — no budget, no exit 1 on size. Bytes are UTF-8 bytes of additionalContext.
#   lint-prompt-length.sh --payload [--json]
#       Runs the REAL scripts/bootstrap.sh (SessionStart) and scripts/inject-phase.sh (UserPromptSubmit)
#       against fixture stdin in a throwaway CLAUDE_PROJECT_DIR. Side effects are neutralized: the plane dir
#       and .plugin-version stamp are pre-created (no claudehut-init / --refresh-rules), `claude` is a PATH
#       stub printing [] (no `claude plugin list` spawn, UA reads "absent"), federation/debug env unset.
#       Two fixtures: "empty" (bare plane) and "realistic" (read-only COPY of learnings.jsonl +
#       .summer-kb-meta.json from CLAUDEHUT_PAYLOAD_SOURCE, default ewallet-workspace/va-ms; skipped if absent).
#   lint-prompt-length.sh --payload-transcripts [--json]
#       Median SessionStart additionalContext bytes as RECORDED in transcripts (hook_additional_context
#       attachments). Glob: CLAUDEHUT_TRANSCRIPT_GLOB (default: ewallet-workspace-* main transcripts).
#       "raw" = bytes of the recorded content (a >~10 KB context is recorded as a <persisted-output> preview,
#       which is what the audit measured); "resolved" swaps each preview for the size of its saved file.
#   lint-prompt-length.sh --payload-self-test   # synthetic fixtures for the two modes above
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Per-file line budgets. Default by category; overrides for the legitimately-larger orchestration prompts.
# SKILL-F1: claudehut-workflow (119 lines) and claudehut-reviewer (90) each carry an explicit BYTE budget
# but fell through to the default LINE budget — 120 and 90 respectively. Sitting one line and zero lines
# from a limit nobody chose for them is an accident, not a decision: the next honest edit trips a budget
# that was never calibrated for that file. Both are now explicit, with the same modest headroom the other
# named entries have. This is not a re-growth allowance — the byte budgets are unchanged.
skill_budget() { case "$1" in review) echo 160 ;; implement) echo 210 ;; claudehut-workflow) echo 130 ;; discover) echo 115 ;; *) echo 120 ;; esac; }
agent_budget() { case "$1" in claudehut-implementer) echo 100 ;; claudehut-reuse-scanner) echo 105 ;; claudehut-reviewer) echo 95 ;; claudehut-planner|claudehut-brainstormer) echo 95 ;; *) echo 90 ;; esac; }
# Per-file BYTE budgets. Lines alone do not bound what the model reads: a commit titled "shrink the agent
# corpus" grew one agent by 1,933 B while its line count FELL by 9, because markdown table padding is free
# under `grep -c ''`. Bytes are what the context window pays for. Seeded ~15% above post-unpad sizes.
skill_bytes()  { case "$1" in review) echo 14000 ;; implement) echo 14500 ;; claudehut-workflow) echo 12000 ;; discover) echo 7500 ;; *) echo 6000 ;; esac; }
agent_bytes()  { case "$1" in claudehut-reuse-scanner|claudehut-planner) echo 7800 ;; claudehut-brainstormer) echo 7500 ;; claudehut-implementer|claudehut-reviewer) echo 7200 ;; *) echo 6000 ;; esac; }
# Provenance tags that belong in the research docs, not the always-loaded body. (M2: the `measured` pattern
# requires the audit FRACTION form `measured N/M` — so benign prose like "measured 3 outcomes" is NOT flagged.)
# SKILL-F12: widened. The old pattern missed BENCH-REPORT entirely, and required "Issue N" to sit
# immediately after an open paren — so "(WS-6, Issue 5)" sailed through. v0.N release tags are provenance
# too: an always-loaded body should state the rule, not when it changed. Benign "v2 API" and bare
# "measured latency" are deliberately NOT matched, and self-test (g) pins that.
PROV='EVAL-REPORT|BENCH-REPORT|RC-[0-9]|audit B\.[0-9]|Issue [0-9]|\(WS-[0-9]|v0\.[0-9]|measured [0-9]+/[0-9]+'

violations=0
flag() { echo "  FLAG - $1"; violations=$((violations+1)); }

lint_file() { # $1 path  $2 line-budget  $3 label  [$4 byte-budget]
  local f="$1" budget="$2" label="$3" bytebudget="${4:-0}" n b
  [ -f "$f" ] || return 0
  n="$(grep -c '' "$f" 2>/dev/null || echo 0)"
  [ "$n" -le "$budget" ] || flag "$label: $n lines > budget $budget (tighten or extract to references/)"
  if [ "$bytebudget" -gt 0 ]; then
    b="$(wc -c <"$f" 2>/dev/null | tr -d ' ')"; b="${b:-0}"
    [ "$b" -le "$bytebudget" ] || flag "$label: $b bytes > budget $bytebudget (tighten or extract to references/)"
  fi
  if grep -nEq "$PROV" "$f" 2>/dev/null; then
    flag "$label: provenance/audit tags in the always-loaded body (move to the research docs): $(grep -noE "$PROV" "$f" | head -3 | tr '\n' ' ')"
  fi
}

run_repo() {
  echo "== prompt-length + provenance lint =="
  local d n
  for d in "$ROOT"/skills/*/; do n="$(basename "$d")"; lint_file "$d/SKILL.md" "$(skill_budget "$n")" "skill:$n" "$(skill_bytes "$n")"; done
  for f in "$ROOT"/agents/*.md; do n="$(basename "$f" .md)"; lint_file "$f" "$(agent_budget "$n")" "agent:$n" "$(agent_bytes "$n")"; done
  if [ "$violations" -eq 0 ]; then echo "  ok - all skill/agent bodies within budget + provenance-clean"; return 0; fi
  echo "  $violations violation(s)"; return 1
}

self_test() {
  # M1: drive the REAL lint_file against synthetic fixtures (not a re-implemented predicate) so a bug in
  # lint_file's budget lookup / comparison is actually caught. lint_file mutates the global `violations`.
  local t; t="$(mktemp -d)"; local pass=0 fail=0
  chk() { if eval "$2"; then pass=$((pass+1)); echo "  ok - $1"; else fail=$((fail+1)); echo "  FAIL - $1"; fi; }

  # (a) over-budget file → ≥1 violation
  { for i in $(seq 1 130); do echo "line $i"; done; } > "$t/over.md"
  violations=0; lint_file "$t/over.md" 120 "test:over" >/dev/null; local v_over=$violations
  chk "lint_file flags an over-budget file (130 > 120)" '[ "$v_over" -ge 1 ]'

  # (b) provenance tag (within length) → ≥1 violation
  printf '# a\nthis cites EVAL-REPORT #7 and (Issue 3) inline\n' > "$t/prov.md"
  violations=0; lint_file "$t/prov.md" 120 "test:prov" >/dev/null; local v_prov=$violations
  chk "lint_file flags a provenance tag in a within-budget file" '[ "$v_prov" -ge 1 ]'

  # (c) clean, within-budget file → 0 violations (no false positive)
  printf '# ok\nshort and clean\nmeasured 3 outcomes today\n' > "$t/clean.md"   # benign "measured 3" must NOT trip (M2)
  violations=0; lint_file "$t/clean.md" 120 "test:clean" >/dev/null; local v_clean=$violations
  chk "lint_file does NOT flag a clean file (incl. benign 'measured 3' — no false positive)" '[ "$v_clean" -eq 0 ]'

  # (d) within line budget but OVER byte budget -> >=1 violation (the padding loophole this closes)
  { for i in $(seq 1 10); do printf 'x%.0s' $(seq 1 300); echo; done; } > "$t/fat.md"
  violations=0; lint_file "$t/fat.md" 120 "test:fat" 1000 >/dev/null; local v_fat=$violations
  chk "lint_file flags a file within its LINE budget but over its BYTE budget" '[ "$v_fat" -ge 1 ]'

  # (e) byte budget of 0 disables the byte check (back-compat for callers passing no 4th arg)
  violations=0; lint_file "$t/fat.md" 120 "test:fat0" 0 >/dev/null; local v_fat0=$violations
  chk "lint_file skips the byte check when the byte budget is 0" '[ "$v_fat0" -eq 0 ]'

  # (g) SKILL-F12 guard, written BEFORE the regex was widened: benign product prose must survive. "v2 API"
  # and "measured latency" read like provenance to a careless pattern; only v0.N and the audit-fraction
  # form are provenance in this corpus.
  printf '# ok\nthe v2 API replaces v1; we measured latency under load and it held\n' > "$t/benign.md"
  violations=0; lint_file "$t/benign.md" 120 "test:benign" >/dev/null; local v_benign=$violations
  chk "lint_file does NOT flag benign product prose (\"v2 API\", \"measured latency\")" '[ "$v_benign" -eq 0 ]'

  # (h) the widened patterns must actually fire
  printf '# x\nsee BENCH-REPORT and (WS-6, Issue 5) from v0.8 WS-9\n' > "$t/prov2.md"
  violations=0; lint_file "$t/prov2.md" 120 "test:prov2" >/dev/null; local v_p2=$violations
  chk "lint_file flags BENCH-REPORT / (WS-N, Issue N) / v0.N provenance" '[ "$v_p2" -ge 1 ]'

  # (f) every skill/agent that has an explicit BYTE budget must also have an explicit LINE budget. A file
  # with one and not the other silently inherits a default calibrated for a different file — which is how
  # claudehut-workflow ended up one line from a limit nobody chose for it.
  local mismatched=0 n
  for n in review implement claudehut-workflow discover; do
    [ "$(skill_budget "$n")" = "120" ] && [ "$(skill_bytes "$n")" != "6000" ] && mismatched=$((mismatched+1))
  done
  for n in claudehut-reuse-scanner claudehut-planner claudehut-brainstormer claudehut-implementer claudehut-reviewer; do
    [ "$(agent_budget "$n")" = "90" ] && [ "$(agent_bytes "$n")" != "6000" ] && mismatched=$((mismatched+1))
  done
  chk "every file with an explicit byte budget also has an explicit line budget" '[ "$mismatched" -eq 0 ]'

  rm -rf "$t"; violations=0
  echo "  self-test: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
}

# ---------------- payload measurement (M0) ----------------
# Defaults; the CLAUDEHUT_* env vars override them at call time (the self-test relies on that).
DEFAULT_TRANSCRIPT_GLOB="$HOME/.claude/projects/-Users-taiphan-Documents-Projects-ewallet-workspace-*/*.jsonl"
DEFAULT_PAYLOAD_SOURCE="$HOME/Documents/Projects/ewallet-workspace/va-ms"
PAYLOAD_PROMPT='cần thêm filter support cho display name ở api dynamic va view'
PAYLOAD_SID='payload-fixture-0001'

ctx_bytes() { jq -r '.hookSpecificOutput.additionalContext // "" | utf8bytelength' 2>/dev/null || echo -1; }

# $1 = fixture project dir, $2 = optional source service dir. Prepares the plane so bootstrap takes no
# init/refresh branch; copies (never links) the source's learnings + KB meta.
payload_fixture() {
  local p="$1" src="${2:-}" v
  mkdir -p "$p/.claude/claudehut/state"
  v="$(jq -r '.version // empty' "$ROOT/.claude-plugin/plugin.json" 2>/dev/null)"
  printf '%s' "$v" > "$p/.claude/claudehut/.plugin-version"
  if [ -n "$src" ]; then
    [ -f "$src/.claude/claudehut/learnings.jsonl" ] && cp "$src/.claude/claudehut/learnings.jsonl" "$p/.claude/claudehut/"
    [ -f "$src/.claude/summer-kb/.summer-kb-meta.json" ] && { mkdir -p "$p/.claude/summer-kb"; cp "$src/.claude/summer-kb/.summer-kb-meta.json" "$p/.claude/summer-kb/"; }
  fi
}

# $1 = fixture project dir, $2 = stub bin dir, $3 = script, stdin = hook payload. Prints the hook's stdout.
payload_run() {
  env -u CLAUDEHUT_FEDERATION_ROOT -u CLAUDEHUT_DEBUG_PAYLOAD \
    PATH="$2:$PATH" CLAUDE_PROJECT_DIR="$1" CLAUDE_PLUGIN_ROOT="$ROOT" bash "$ROOT/scripts/$3" 2>/dev/null
}

# $1 = fixture project dir, $2 = stub bin dir, $3 = label. Prints one JSON object.
payload_measure() {
  local p="$1" b="$2" label="$3" ss u1 u2 um
  ss="$(printf '{"session_id":"%s","source":"startup","hook_event_name":"SessionStart"}' "$PAYLOAD_SID" \
        | payload_run "$p" "$b" bootstrap.sh | ctx_bytes)"
  local up; up="$(jq -nc --arg s "$PAYLOAD_SID" --arg q "$PAYLOAD_PROMPT" '{session_id:$s,prompt:$q,hook_event_name:"UserPromptSubmit"}')"
  u1="$(printf '%s' "$up" | payload_run "$p" "$b" inject-phase.sh | ctx_bytes)"   # first prompt: full phase block
  u2="$(printf '%s' "$up" | payload_run "$p" "$b" inject-phase.sh | ctx_bytes)"   # same phase again: delta path
  um="$(jq -nc --arg s "$PAYLOAD_SID" '{session_id:$s,prompt:"<task-notification><status>completed</status></task-notification>",hook_event_name:"UserPromptSubmit"}' \
        | payload_run "$p" "$b" inject-phase.sh | ctx_bytes)"                  # machine-generated turn (F-6)
  jq -nc --arg l "$label" --argjson ss "$ss" --argjson u1 "$u1" --argjson u2 "$u2" --argjson um "$um" \
    --argjson learn "$([ -f "$p/.claude/claudehut/learnings.jsonl" ] && grep -c '' "$p/.claude/claudehut/learnings.jsonl" || echo 0)" \
    --argjson kb "$([ -f "$p/.claude/summer-kb/.summer-kb-meta.json" ] && echo true || echo false)" \
    '{fixture:$l, learnings_entries:$learn, summer_kb:$kb, session_start_bytes:$ss,
      user_prompt_submit_first_bytes:$u1, user_prompt_submit_repeat_bytes:$u2, user_prompt_submit_machine_turn_bytes:$um}'
}

run_payload() { # [$1 = --json]
  local t; t="$(mktemp -d)"; mkdir -p "$t/bin"
  printf '#!/bin/sh\necho "[]"\n' > "$t/bin/claude"; chmod +x "$t/bin/claude"
  local digest="$ROOT/skills/claudehut-workflow/references/digest.md" dbytes rows
  local PAYLOAD_SOURCE="${CLAUDEHUT_PAYLOAD_SOURCE:-$DEFAULT_PAYLOAD_SOURCE}"
  dbytes="$(wc -c <"$digest" 2>/dev/null | tr -d ' ')"
  payload_fixture "$t/empty"; rows="$(payload_measure "$t/empty" "$t/bin" empty)"
  if [ -d "$PAYLOAD_SOURCE/.claude/claudehut" ]; then
    payload_fixture "$t/realistic" "$PAYLOAD_SOURCE"
    rows="$rows"$'\n'"$(payload_measure "$t/realistic" "$t/bin" "realistic:$(basename "$PAYLOAD_SOURCE")")"
  fi
  local out; out="$(printf '%s\n' "$rows" | jq -sc --argjson d "${dbytes:-0}" --arg v "$(jq -r .version "$ROOT/.claude-plugin/plugin.json")" \
    --arg prompt "$PAYLOAD_PROMPT" '{plugin_version:$v, digest_bytes:$d, prompt:$prompt, fixtures:.}')"
  rm -rf "$t"
  if [ "${1:-}" = "--json" ]; then printf '%s\n' "$out"; return 0; fi
  echo "== hook payload (UTF-8 bytes of additionalContext, plugin $(jq -r .plugin_version <<<"$out")) =="
  echo "  digest.md: $(jq -r .digest_bytes <<<"$out") B"
  jq -r '.fixtures[] | "  \(.fixture): SessionStart \(.session_start_bytes) B · UserPromptSubmit first \(.user_prompt_submit_first_bytes) B / repeat \(.user_prompt_submit_repeat_bytes) B / machine turn \(.user_prompt_submit_machine_turn_bytes) B (learnings=\(.learnings_entries), summer_kb=\(.summer_kb))"' <<<"$out"
}

run_payload_transcripts() { # [$1 = --json]
  CLAUDEHUT_TRANSCRIPT_GLOB="${CLAUDEHUT_TRANSCRIPT_GLOB:-$DEFAULT_TRANSCRIPT_GLOB}" python3 - "${1:-}" <<'PY'
import glob, json, os, re, statistics, sys
files = sorted(glob.glob(os.environ["CLAUDEHUT_TRANSCRIPT_GLOB"]))
raw, resolved, ups, pers, unresolved = [], [], [], 0, 0
for p in files:
    with open(p, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            if '"hook_additional_context"' not in line: continue
            try: a = json.loads(line).get("attachment") or {}
            except ValueError: continue
            if a.get("type") != "hook_additional_context": continue
            c = a.get("content"); items = c if isinstance(c, list) else [str(c or "")]
            b = sum(len(str(x).encode()) for x in items)
            if a.get("hookEvent") == "UserPromptSubmit": ups.append(b); continue
            if a.get("hookEvent") != "SessionStart": continue
            raw.append(b); tot, ok = 0, True
            for x in items:
                x = str(x); m = re.search(r"Full output saved to: (\S+)", x)
                if x.startswith("<persisted-output>") and m:
                    pers += 1
                    if os.path.isfile(m.group(1)): tot += os.path.getsize(m.group(1))
                    else: ok = False
                else: tot += len(x.encode())
            if ok: resolved.append(tot)
            else: unresolved += 1
med = lambda v: statistics.median(v) if v else None
out = {"transcripts": len(files),
       "session_start": {"n": len(raw), "median_raw_bytes": med(raw), "mean_raw_bytes": round(statistics.mean(raw), 1) if raw else None,
                         "min": min(raw) if raw else None, "max": max(raw) if raw else None, "persisted_previews": pers,
                         "resolved_n": len(resolved), "resolved_unavailable": unresolved, "median_resolved_bytes": med(resolved)},
       "user_prompt_submit": {"n": len(ups), "total_raw_bytes": sum(ups), "median_raw_bytes": med(ups),
                              "note": "all plugins' UserPromptSubmit context, informational"}}
if not files:
    print("  SKIP - no transcripts match CLAUDEHUT_TRANSCRIPT_GLOB"); sys.exit(0)
if sys.argv[1:] == ["--json"]: print(json.dumps(out, ensure_ascii=False)); sys.exit(0)
s = out["session_start"]
print("== SessionStart additionalContext as recorded in transcripts ==")
print(f"  {out['transcripts']} transcripts, {s['n']} records: median raw {s['median_raw_bytes']} B (mean {s['mean_raw_bytes']}, min {s['min']}, max {s['max']})")
print(f"  {s['persisted_previews']} persisted previews; resolved median {s['median_resolved_bytes']} B over {s['resolved_n']} records ({s['resolved_unavailable']} unavailable)")
u = out["user_prompt_submit"]
print(f"  UserPromptSubmit (all plugins, informational): {u['n']} records, {u['total_raw_bytes']} B total")
PY
}

payload_self_test() {
  local t; t="$(mktemp -d)"; local pass=0 fail=0 j
  chk() { if eval "$2"; then pass=$((pass+1)); echo "  ok - $1"; else fail=$((fail+1)); echo "  FAIL - $1"; fi; }
  # (p1) transcripts: 3 SessionStart records of 10/20/30 B -> median 20; one persisted preview resolves to its file.
  mkdir -p "$t/proj"; head -c 5000 /dev/zero | tr '\0' 'x' > "$t/saved.txt"
  { for n in 10 20 30; do jq -nc --arg c "$(head -c "$n" /dev/zero | tr '\0' 'a')" '{type:"attachment",attachment:{type:"hook_additional_context",hookEvent:"SessionStart",content:[$c]}}'; done
    jq -nc --arg c "<persisted-output>
Output too large. Full output saved to: $t/saved.txt
" '{type:"attachment",attachment:{type:"hook_additional_context",hookEvent:"SessionStart",content:[$c]}}'
    jq -nc '{type:"attachment",attachment:{type:"hook_additional_context",hookEvent:"UserPromptSubmit",content:["abc"]}}'
  } > "$t/proj/s.jsonl"
  j="$(CLAUDEHUT_TRANSCRIPT_GLOB="$t/proj/*.jsonl" run_payload_transcripts --json)"
  chk "transcripts: 4 SessionStart records counted, UserPromptSubmit kept separate" '[ "$(jq .session_start.n <<<"$j")" = 4 ] && [ "$(jq .user_prompt_submit.n <<<"$j")" = 1 ]'
  chk "transcripts: persisted preview resolves to the saved file size" '[ "$(jq .session_start.persisted_previews <<<"$j")" = 1 ] && [ "$(jq .session_start.resolved_n <<<"$j")" = 4 ] && jq -e ".session_start.median_resolved_bytes == 25" <<<"$j" >/dev/null'
  chk "transcripts: no match -> SKIP, exit 0" 'CLAUDEHUT_TRANSCRIPT_GLOB="$t/none/*.jsonl" run_payload_transcripts | grep -q SKIP'
  # (p2) live hooks on an empty fixture: real bootstrap/inject-phase emit context; the repo is not touched.
  touch "$t/marker"; sleep 1
  j="$(CLAUDEHUT_PAYLOAD_SOURCE="$t/no-such-source" run_payload --json)"
  chk "payload: SessionStart context >= digest.md (digest is its first block)" 'jq -e ".fixtures[0].session_start_bytes >= .digest_bytes and .digest_bytes > 0" <<<"$j" >/dev/null'
  chk "payload: first UserPromptSubmit carries the full block, repeat takes the delta path" 'jq -e ".fixtures[0] | .user_prompt_submit_first_bytes > .user_prompt_submit_repeat_bytes and .user_prompt_submit_repeat_bytes > 0" <<<"$j" >/dev/null'
  chk "payload: absent source -> only the empty fixture" '[ "$(jq ".fixtures|length" <<<"$j")" = 1 ]'
  chk "payload: no file under the repo was modified" '[ -z "$(find "$ROOT" -path "$ROOT/.git" -prune -o -type f -newer "$t/marker" -print | head -1)" ]'
  rm -rf "$t"
  echo "  payload self-test: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --self-test) self_test ;;
  --payload) run_payload "${2:-}" ;;
  --payload-transcripts) run_payload_transcripts "${2:-}" ;;
  --payload-self-test) payload_self_test ;;
  *) run_repo ;;
esac
