#!/usr/bin/env bash
# Review fan-out cost from real transcripts (M0 baseline; audit E1, E4, E7, A3). Read-only, measurement only.
#
# Usage:
#   review-cost.sh [--gap SECONDS] [--json]   # report; default gap 300
#   review-cost.sh --self-test                # synthetic transcripts, no real data needed
#
# Input: CLAUDEHUT_TRANSCRIPT_GLOB (default: ewallet-workspace-* main-thread transcripts). Subagent transcripts
# are found next to each main transcript at <session-id>/subagents/agent-*.jsonl; the sibling *.meta.json
# carries agentType and the toolUseId of the Agent call that launched it — that is the only link used.
#
# AUDITOR = an Agent/Task tool_use whose subagent_type is one of the 7 review kinds (claudehut:claudehut-
# test-runner|reviewer|security-auditor|perf-reviewer|db-reviewer|observability-reviewer|contract-reviewer).
# plan-reviewer is NOT a code auditor. Dispatches under a teammate `name` with another subagent_type are not
# counted (the audit's 208 are exactly the typed dispatches).
#
# WAVE HEURISTIC: within one main transcript, auditor dispatches sorted by timestamp; a dispatch joins the
# current wave when it is <= GAP seconds after the PREVIOUS auditor dispatch, otherwise it opens a new wave.
# Not "same assistant message": the v0.11 main thread often issues a fan-out as several consecutive messages
# (message-id grouping gives 77 waves / 24 with >=4 / 4 with all 7 on the ewallet data). The gap result is
# flat from 120 s to 600 s (52 / 28 / 7, matching E1) and only drifts below 60 s or above ~30 min; the
# report prints that sensitivity row so a reader can see the plateau instead of trusting one number.
#
# TOKENS: one API response is written as several transcript records carrying the same message.id and the
# same usage, so usage is de-duplicated by message.id before summing. input = input_tokens +
# cache_creation_input_tokens + cache_read_input_tokens (cache_read also reported alone). Only dispatches
# with a linked subagent transcript have tokens/wall time; coverage is reported with its denominator.
# WALL TIME: first to last timestamp in the subagent transcript (dispatches launch async, so the Agent
# tool_result time is not the finish time); a wave's wall = earliest start to latest end of linked members.
#
# GIT DIFF (E4): Bash tool_use calls (unique tool_use id) whose command contains `git diff`, inside auditor
# subagent transcripts.
# COMPLEXITY (A3): `set-complexity <trivial|small|full>` inside main-thread Bash tool_use commands.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEFAULT_GLOB="$HOME/.claude/projects/-Users-taiphan-Documents-Projects-ewallet-workspace-*/*.jsonl"

analyze() { # $@ = python args
  CLAUDEHUT_TRANSCRIPT_GLOB="${CLAUDEHUT_TRANSCRIPT_GLOB:-$DEFAULT_GLOB}" python3 - "$@" <<'PY'
import glob, json, os, re, statistics, sys
from datetime import datetime

args = sys.argv[1:]
gap = float(args[args.index("--gap") + 1]) if "--gap" in args else 300.0
as_json = "--json" in args
KINDS = ["test-runner", "reviewer", "security-auditor", "perf-reviewer", "db-reviewer", "observability-reviewer", "contract-reviewer"]
CX = re.compile(r"set-complexity\s+[\"']?(trivial|small|full)\b")

def kind(t):
    t = (t or "").split(":")[-1]
    t = t[len("claudehut-"):] if t.startswith("claudehut-") else None
    return t if t in KINDS else None

def ts(s):
    try: return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except Exception: return None

def records(p):
    with open(p, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            try: yield json.loads(line)
            except ValueError: continue

def tool_uses(r, seen):
    # A tool_use id is unique; skip one already seen (a response re-written across records).
    if r.get("type") != "assistant": return
    for c in (r.get("message") or {}).get("content") or []:
        if isinstance(c, dict) and c.get("type") == "tool_use" and c.get("id") not in seen:
            seen.add(c.get("id")); yield c

def sub_stats(p):
    usage, t0, t1, diffs, seen = {}, None, None, 0, set()
    for r in records(p):
        t = ts(r.get("timestamp") or "")
        if t is not None: t0 = t if t0 is None else min(t0, t); t1 = t if t1 is None else max(t1, t)
        m = r.get("message") or {}
        if r.get("type") == "assistant" and m.get("usage"):
            usage[m.get("id") or id(r)] = m["usage"]
        for c in tool_uses(r, seen):
            if c.get("name") == "Bash" and "git diff" in str((c.get("input") or {}).get("command", "")): diffs += 1
    g = lambda k: sum(int(u.get(k) or 0) for u in usage.values())
    return {"input": g("input_tokens") + g("cache_creation_input_tokens") + g("cache_read_input_tokens"),
            "cache_read": g("cache_read_input_tokens"), "output": g("output_tokens"),
            "start": t0, "end": t1, "git_diff": diffs}

mains = sorted(glob.glob(os.environ["CLAUDEHUT_TRANSCRIPT_GLOB"]))
if not mains:
    print("  SKIP - no transcripts match CLAUDEHUT_TRANSCRIPT_GLOB"); sys.exit(0)

dispatches, cx, git_diff, auditor_subs = [], {}, 0, 0
for p in mains:
    subdir = os.path.join(p[:-len(".jsonl")], "subagents")
    link = {}
    for meta in glob.glob(os.path.join(subdir, "*.meta.json")):
        try: mj = json.load(open(meta, encoding="utf-8"))
        except Exception: continue
        jl = meta[:-len(".meta.json")] + ".jsonl"
        if not kind(mj.get("agentType")) or not os.path.isfile(jl): continue
        st = sub_stats(jl); auditor_subs += 1; git_diff += st["git_diff"]
        if mj.get("toolUseId"): link[mj["toolUseId"]] = st
    seen = set()
    for r in records(p):
        for c in tool_uses(r, seen):
            inp = c.get("input") or {}
            if c.get("name") == "Bash":
                for m in CX.findall(str(inp.get("command", ""))): cx[m] = cx.get(m, 0) + 1
            if c.get("name") in ("Agent", "Task") and kind(inp.get("subagent_type")):
                dispatches.append({"file": p, "t": ts(r.get("timestamp") or "") or 0.0, "mid": (r.get("message") or {}).get("id"),
                                   "kind": kind(inp.get("subagent_type")), "sub": link.get(c.get("id"))})

def waves_by_gap(g):
    out = []
    for d in sorted(dispatches, key=lambda d: (d["file"], d["t"])):
        if out and out[-1][-1]["file"] == d["file"] and d["t"] - out[-1][-1]["t"] <= g: out[-1].append(d)
        else: out.append([d])
    return out

def shape(ws):
    return {"waves": len(ws), "waves_ge4_auditors": sum(len(w) >= 4 for w in ws),
            "waves_all7_kinds": sum(len({d["kind"] for d in w}) == 7 for w in ws)}

waves = waves_by_gap(gap)
rows = []
for w in waves:
    linked = [d["sub"] for d in w if d["sub"]]
    starts = [s["start"] for s in linked if s["start"] is not None]; ends = [s["end"] for s in linked if s["end"] is not None]
    parts = w[0]["file"].split(os.sep)
    rows.append({"project": parts[-2].split("ewallet-workspace-")[-1], "session": parts[-1][:8],
                 "start": datetime.utcfromtimestamp(w[0]["t"]).strftime("%Y-%m-%dT%H:%M:%SZ"),
                 "auditors": len(w), "kinds": sorted({d["kind"] for d in w}), "linked": len(linked),
                 "input_tokens": sum(s["input"] for s in linked) if linked else None,
                 "cache_read_tokens": sum(s["cache_read"] for s in linked) if linked else None,
                 "output_tokens": sum(s["output"] for s in linked) if linked else None,
                 "wall_s": round(max(ends) - min(starts)) if starts and ends else None})
full = [r for r in rows if r["linked"] == r["auditors"]]
full4 = [r for r in full if r["auditors"] >= 4]
med = lambda v: statistics.median(v) if v else None
msgid = {}
for d in dispatches: msgid.setdefault((d["file"], d["mid"]), []).append(d)
out = {"transcripts": len(mains), "gap_s": gap, "auditor_dispatches": len(dispatches),
       "dispatches_with_subagent_transcript": sum(1 for d in dispatches if d["sub"]),
       **shape(waves),
       "sensitivity": {**{f"gap_{g}s": shape(waves_by_gap(g)) for g in (60, 120, 300, 600, 1800)},
                       "same_message_id": shape(list(msgid.values()))},
       "fully_linked_waves": len(full),
       "median_wave_input_tokens": med([r["input_tokens"] for r in full]),
       "median_wave_output_tokens": med([r["output_tokens"] for r in full]),
       "median_wave_wall_s": med([r["wall_s"] for r in full if r["wall_s"] is not None]),
       # E1's cost row (08-review.md: 22,1M / 118k / 12,7 min) is the median over waves with >=4 auditors.
       "fully_linked_ge4_waves": len(full4),
       "median_ge4_wave_input_tokens": med([r["input_tokens"] for r in full4]),
       "median_ge4_wave_output_tokens": med([r["output_tokens"] for r in full4]),
       "median_ge4_wave_wall_s": med([r["wall_s"] for r in full4 if r["wall_s"] is not None]),
       "median_output_tokens_per_auditor": med([d["sub"]["output"] for d in dispatches if d["sub"]]),
       "auditor_subagent_transcripts": auditor_subs, "auditor_git_diff_calls": git_diff,
       "complexity": {**cx, "total": sum(cx.values())}, "per_wave": rows}
if as_json:
    print(json.dumps(out, ensure_ascii=False)); sys.exit(0)
print(f"== review fan-out ({out['transcripts']} main transcripts, gap {gap:g}s) ==")
print(f"  auditor dispatches: {out['auditor_dispatches']} ({out['dispatches_with_subagent_transcript']} with a linked subagent transcript)")
print(f"  waves: {out['waves']} · >=4 auditors: {out['waves_ge4_auditors']} · all 7 kinds: {out['waves_all7_kinds']}")
print("  sensitivity: " + " · ".join(f"{k} {v['waves']}/{v['waves_ge4_auditors']}/{v['waves_all7_kinds']}" for k, v in out["sensitivity"].items()))
print(f"  fully linked waves: {out['fully_linked_waves']} · median input {out['median_wave_input_tokens']} · output {out['median_wave_output_tokens']} · wall {out['median_wave_wall_s']} s")
print(f"  fully linked waves with >=4 auditors: {out['fully_linked_ge4_waves']} · median input {out['median_ge4_wave_input_tokens']} · output {out['median_ge4_wave_output_tokens']} · wall {out['median_ge4_wave_wall_s']} s")
print(f"  median output/auditor: {out['median_output_tokens_per_auditor']} · auditor 'git diff' calls: {git_diff} in {auditor_subs} auditor transcripts")
print(f"  set-complexity: {json.dumps(out['complexity'])}")
PY
}

self_test() {
  local t; t="$(mktemp -d)"; local pass=0 fail=0 j
  chk() { if eval "$2"; then pass=$((pass+1)); echo "  ok - $1"; else fail=$((fail+1)); echo "  FAIL - $1"; fi; }
  local P="$t/proj" S="$t/proj/sess0001/subagents"; mkdir -p "$S"
  # Wave A: all 7 kinds, 10 s apart (two assistant messages). Wave B: 2 auditors 1000 s later. One explorer (not an auditor).
  {
    i=0; for k in test-runner reviewer security-auditor perf-reviewer db-reviewer observability-reviewer contract-reviewer; do
      i=$((i+1)); jq -nc --arg k "claudehut:claudehut-$k" --arg id "tu$i" --arg ts "2026-09-01T00:00:$(printf %02d $((i*5)))Z" --arg m "msg$(( i<=4 ? 1 : 2 ))" \
        '{type:"assistant",timestamp:$ts,message:{id:$m,content:[{type:"tool_use",id:$id,name:"Agent",input:{subagent_type:$k,prompt:"x"}}]}}'
    done
    jq -nc '{type:"assistant",timestamp:"2026-09-01T00:17:00Z",message:{id:"m9",content:[{type:"tool_use",id:"tu8",name:"Agent",input:{subagent_type:"claudehut:claudehut-reviewer"}},{type:"tool_use",id:"tu9",name:"Agent",input:{subagent_type:"claudehut:claudehut-explorer"}}]}}'
    jq -nc '{type:"assistant",timestamp:"2026-09-01T00:17:05Z",message:{id:"m10",content:[{type:"tool_use",id:"tu10",name:"Agent",input:{subagent_type:"claudehut:claudehut-db-reviewer"}}]}}'
    jq -nc '{type:"assistant",timestamp:"2026-09-01T00:18:00Z",message:{id:"m11",content:[{type:"tool_use",id:"b1",name:"Bash",input:{command:"claudehut-state set-complexity full && claudehut-state set-complexity small"}}]}}'
  } > "$P/sess0001.jsonl"
  # tu1 linked: one API response split into 2 records with identical usage (must count once) + one git diff call.
  jq -nc '{agentType:"claudehut:claudehut-test-runner",toolUseId:"tu1"}' > "$S/agent-a1.meta.json"
  { jq -nc '{type:"user",timestamp:"2026-09-01T00:00:06Z",message:{content:"go"}}'
    for n in 1 2; do jq -nc '{type:"assistant",timestamp:"2026-09-01T00:01:06Z",message:{id:"r1",usage:{input_tokens:10,cache_creation_input_tokens:100,cache_read_input_tokens:1000,output_tokens:50},content:[{type:"tool_use",id:"g1",name:"Bash",input:{command:"git diff HEAD~1"}}]}}'; done
  } > "$S/agent-a1.jsonl"
  j="$(CLAUDEHUT_TRANSCRIPT_GLOB="$P/*.jsonl" analyze --json)"
  chk "9 auditor dispatches counted, the explorer is not" '[ "$(jq .auditor_dispatches <<<"$j")" = 9 ]'
  chk "gap grouping: 2 waves, 1 with >=4 auditors, 1 with all 7 kinds" '[ "$(jq -c "[.waves,.waves_ge4_auditors,.waves_all7_kinds]" <<<"$j")" = "[2,1,1]" ]'
  chk "message-id grouping is reported separately (4 groups)" '[ "$(jq .sensitivity.same_message_id.waves <<<"$j")" = 4 ]'
  chk "usage de-duplicated by message.id (input 1110, output 50, not doubled)" '[ "$(jq -c "[.per_wave[0].input_tokens,.per_wave[0].output_tokens,.per_wave[0].linked]" <<<"$j")" = "[1110,50,1]" ]'
  chk "wall time from the subagent transcript (60 s)" '[ "$(jq .per_wave[0].wall_s <<<"$j")" = 60 ]'
  chk "a partly linked wave is not a fully linked wave" '[ "$(jq .fully_linked_waves <<<"$j")" = 0 ]'
  chk "a partly linked >=4 wave is not in the E1 cost median" '[ "$(jq -c "[.fully_linked_ge4_waves,.median_ge4_wave_input_tokens]" <<<"$j")" = "[0,null]" ]'
  chk "auditor git diff counted once per Bash tool_use id (a response re-written across 2 records -> 1)" '[ "$(jq .auditor_git_diff_calls <<<"$j")" = 1 ]'
  chk "set-complexity: every tier mention in a Bash command counted" '[ "$(jq -c ".complexity" <<<"$j")" = "{\"full\":1,\"small\":1,\"total\":2}" ]'
  chk "no transcripts -> SKIP, exit 0" 'CLAUDEHUT_TRANSCRIPT_GLOB="$t/none/*.jsonl" analyze | grep -q SKIP'
  rm -rf "$t"
  echo "  self-test: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
}

case "${1:-}" in
  --self-test) self_test ;;
  *) analyze "$@" ;;
esac
