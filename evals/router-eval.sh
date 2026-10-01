#!/usr/bin/env bash
# Router eval harness for the v0.12 routing rubric (04-routing-harness.md §2: direct | light | full, plus
# `ask` when two adjacent routes are both reasonable). Cases: evals/router-cases.jsonl — real ewallet prompts,
# redacted, one expected route + one-line rationale each.
#
# NO live model calls happen unless --model-cmd or --digest is given.
#
# Usage:
#   router-eval.sh [--cases FILE]                      # dry-run: print id, expected route, first prompt line
#   router-eval.sh --validate [--cases FILE]           # schema check; exit 1 on any error
#   router-eval.sh --model-cmd 'CMD' [--cases FILE]    # later milestones: CMD reads the prompt on stdin and
#                                                      # prints a route word; reports accuracy and the §5
#                                                      # invariant "0 full-labelled prompt routed to direct"
#   router-eval.sh --digest FILE [--model M] [--cases FILE]
#                                                      # scores a digest: each case goes to `claude -p` (model
#                                                      # M, default sonnet) with FILE as appended system context,
#                                                      # no tools, no settings/plugins/MCP, cwd a temp dir. The
#                                                      # model answers `ROUTE: <word>` in its digest's own
#                                                      # vocabulary (trivial->direct, small->light) and
#                                                      # `FIRST_ACTION: ...`. Single trial, self-reported action.
#   router-eval.sh --self-test                         # validator discriminates bad fixtures
#
# Score report: accuracy · full->direct (invariant 0, the exit condition) · direct/light->full (compare to the
# v0.11 digest on the same model) · skip-workflow cases (prompt says "skip workflow"): the output must name
# no `start`, no bypass and no AskUserQuestion (exit 1 otherwise).
#
# Case schema (one JSON object per line):
#   id (unique string) · source ("<service>/<session-prefix>") · prompt (non-empty) ·
#   expected_route in direct|light|full|ask · rationale (one line, <=300 chars) ·
#   candidates (ask ONLY: 2 distinct routes from direct|light|full, recommended first) · truncated (optional bool)
# Redaction guard: a prompt must not carry an absolute home path or a credential-looking assignment.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CASES="$ROOT/evals/router-cases.jsonl"
# Neutral: names no route, override or preference, so the v0.11 and v0.12 digests are asked the same thing.
ROUTER_INSTRUCTION='Router eval. You are the main agent at the start of a session that carries the context above. Do not carry out the next user request and do not ask anything now. Reply with exactly two lines:
ROUTE: <the one word the context above uses for how to handle the request (its route or tier name), or ask if you would first ask the user to choose between two>
FIRST_ACTION: <the exact command, tool call or question you would issue first, or none>'

run() { # $1 = mode (dryrun|validate|score)  $2 = cases file  $3 = model cmd
  python3 - "$@" <<'PY'
import json, re, subprocess, sys, collections
mode, path = sys.argv[1], sys.argv[2]
cmd = sys.argv[3] if len(sys.argv) > 3 else ""
ROUTES = {"direct", "light", "full"}
SECRET = re.compile(r"(/Users/|/home/)|((PASSWORD|SECRET|TOKEN|API_KEY)\s*=)", re.I)
errs, cases, ids = [], [], set()
try:
    lines = open(path, encoding="utf-8").read().splitlines()
except OSError as e:
    print(f"  FAIL - cannot read {path}: {e}"); sys.exit(1)
for n, line in enumerate(lines, 1):
    if not line.strip(): continue
    try: c = json.loads(line)
    except ValueError: errs.append(f"line {n}: not JSON"); continue
    if not isinstance(c, dict): errs.append(f"line {n}: not an object"); continue
    cid = c.get("id")
    if not isinstance(cid, str) or not cid: errs.append(f"line {n}: missing id")
    elif cid in ids: errs.append(f"line {n}: duplicate id {cid}")
    else: ids.add(cid)
    for k in ("source", "prompt", "rationale"):
        if not isinstance(c.get(k), str) or not c[k].strip(): errs.append(f"line {n}: missing {k}")
    r = c.get("expected_route")
    if r not in ROUTES | {"ask"}: errs.append(f"line {n}: bad expected_route {r!r}")
    rat = c.get("rationale") or ""
    if isinstance(rat, str) and ("\n" in rat or len(rat) > 300): errs.append(f"line {n}: rationale must be one line <=300 chars")
    cand = c.get("candidates")
    if r == "ask":
        if not (isinstance(cand, list) and len(cand) == 2 and len(set(cand)) == 2 and set(cand) <= ROUTES):
            errs.append(f"line {n}: ask needs candidates = 2 distinct routes")
    elif cand is not None: errs.append(f"line {n}: candidates only allowed on ask")
    if "truncated" in c and not isinstance(c["truncated"], bool): errs.append(f"line {n}: truncated must be bool")
    if isinstance(c.get("prompt"), str) and SECRET.search(c["prompt"]): errs.append(f"line {n}: prompt not redacted (path/credential)")
    cases.append(c)
dist = collections.Counter(c.get("expected_route") for c in cases)
if mode == "validate":
    for e in errs: print(f"  FAIL - {e}")
    print(f"  cases: {len(cases)} · " + " · ".join(f"{k} {dist.get(k, 0)}" for k in ("direct", "light", "full", "ask")))
    print(f"  validate: {'ok' if not errs else str(len(errs)) + ' error(s)'}")
    sys.exit(1 if errs else 0)
if errs:
    print(f"  FAIL - {len(errs)} schema error(s); run --validate"); sys.exit(1)
if mode == "dryrun":
    for c in cases:
        print(f"{c['id']}\t{c['expected_route']}\t{c['prompt'].splitlines()[0][:100]}")
    sys.exit(0)
# score
import concurrent.futures, os
MAP = {"trivial": "direct", "small": "light"}
def ask_model(c):
    try: return subprocess.run(cmd, shell=True, input=c["prompt"], capture_output=True, text=True, timeout=300).stdout
    except subprocess.TimeoutExpired: return ""
def route_of(out):
    m = re.search(r"ROUTE:\s*`?\*{0,2}([a-z]+)", out, re.I) or re.search(r"\b(direct|light|full|ask|trivial|small)\b", out.lower())
    r = m.group(1).lower() if m else "none"
    return MAP.get(r, r)
with concurrent.futures.ThreadPoolExecutor(int(os.environ.get("ROUTER_EVAL_JOBS", "4"))) as ex:
    outs = list(ex.map(ask_model, cases))
hit, full_to_direct, pushed_up, skip_bad, rows = 0, 0, 0, 0, []
for c, out in zip(cases, outs):
    got = route_of(out); exp = c["expected_route"]
    ok = got == exp; hit += ok
    full_to_direct += exp == "full" and got == "direct"
    pushed_up += exp in ("direct", "light") and got == "full"
    fa = re.search(r"FIRST_ACTION:\s*(.*)", out); fa = fa.group(1).strip()[:160] if fa else ""
    note = ""
    if "skip workflow" in c["prompt"].lower():
        bad = re.search(r"\bstart\b[^\n]*--route|claudehut-state[^\n]*\bstart\b|bypass|AskUserQuestion", out, re.I)
        skip_bad += bool(bad) or got != "direct"
        note = f" · skip-workflow: {'FAIL (' + (bad.group(0) if bad else 'route ' + got) + ')' if bad or got != 'direct' else 'no start, no bypass, no ask'}"
    rows.append(f"  {'ok  ' if ok else 'MISS'} {c['id']} expected {exp} got {got}{note}" + (f"\n        first action: {fa}" if fa else ""))
print("\n".join(rows))
print(f"  accuracy {hit}/{len(cases)} · full->direct {full_to_direct} (invariant: 0) · direct/light->full {pushed_up} · skip-workflow violations {skip_bad}")
sys.exit(0 if full_to_direct == 0 and skip_bad == 0 else 1)
PY
}

self_test() {
  local t; t="$(mktemp -d)"; local pass=0 fail=0
  chk() { if eval "$2"; then pass=$((pass+1)); echo "  ok - $1"; else fail=$((fail+1)); echo "  FAIL - $1"; fi; }
  local good='{"id":"a","source":"s/1","prompt":"p","expected_route":"direct","rationale":"r"}'
  printf '%s\n' "$good" '{"id":"b","source":"s/1","prompt":"q","expected_route":"ask","rationale":"r","candidates":["light","full"]}' > "$t/good.jsonl"
  chk "valid file passes" 'run validate "$t/good.jsonl" >/dev/null'
  printf '%s\n' '{"id":"a","source":"s","prompt":"p","expected_route":"medium","rationale":"r"}' > "$t/b1.jsonl"
  chk "bad route fails" '! run validate "$t/b1.jsonl" >/dev/null'
  printf '%s\n' '{"id":"a","source":"s","prompt":"p","expected_route":"full"}' > "$t/b2.jsonl"
  chk "missing rationale fails" '! run validate "$t/b2.jsonl" >/dev/null'
  printf '%s\n' "$good" "$good" > "$t/b3.jsonl"
  chk "duplicate id fails" '! run validate "$t/b3.jsonl" >/dev/null'
  printf '%s\n' '{"id":"a","source":"s","prompt":"p","expected_route":"ask","rationale":"r"}' > "$t/b4.jsonl"
  chk "ask without candidates fails" '! run validate "$t/b4.jsonl" >/dev/null'
  printf '%s\n' '{"id":"a","source":"s","prompt":"see /Users/x/secret PASSWORD=1","expected_route":"direct","rationale":"r"}' > "$t/b5.jsonl"
  chk "unredacted path/credential fails" '! run validate "$t/b5.jsonl" >/dev/null'
  chk "scorer: a model that always answers direct breaks the full->direct invariant" \
    'printf "%s\n" "{\"id\":\"f\",\"source\":\"s\",\"prompt\":\"p\",\"expected_route\":\"full\",\"rationale\":\"r\"}" > "$t/f.jsonl"; ! run score "$t/f.jsonl" "echo direct" >/dev/null'
  chk "scorer: ROUTE: line wins over route words in prose; v0.11 tiers map trivial->direct, small->light" \
    'printf "%s\n" "{\"id\":\"t\",\"source\":\"s\",\"prompt\":\"p\",\"expected_route\":\"direct\",\"rationale\":\"r\"}" > "$t/t.jsonl"; run score "$t/t.jsonl" "printf \"not full\\nROUTE: trivial\\n\"" | grep -q "ok   t expected direct got direct"'
  chk "scorer: counts direct/light pushed to full" \
    'run score "$t/t.jsonl" "echo ROUTE: full" | grep -q "direct/light->full 1"'
  printf '%s\n' '{"id":"k","source":"s","prompt":"do x - skip workflow claudehut","expected_route":"direct","rationale":"r"}' > "$t/k.jsonl"
  chk "scorer: a skip-workflow case that names start fails; a clean direct answer passes" \
    '! run score "$t/k.jsonl" "printf \"ROUTE: direct\\nFIRST_ACTION: claudehut-state start --route light\\n\"" >/dev/null && run score "$t/k.jsonl" "printf \"ROUTE: direct\\nFIRST_ACTION: Read Foo.java\\n\"" >/dev/null'
  chk "shipped router-cases.jsonl validates" 'run validate "$CASES" >/dev/null'
  rm -rf "$t"
  echo "  self-test: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
}

mode=dryrun; cmd=""; digest=""; model=sonnet
while [ $# -gt 0 ]; do
  case "$1" in
    --validate) mode=validate ;;
    --self-test) mode=selftest ;;
    --cases) CASES="$2"; shift ;;
    --model-cmd) mode=score; cmd="$2"; shift ;;
    --digest) mode=score; digest="$2"; shift ;;
    --model) model="$2"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done
case "$mode" in
  selftest) self_test ;;
  score)
    if [ -n "$digest" ]; then
      [ -f "$digest" ] || { echo "no digest file: $digest" >&2; exit 2; }
      wd="$(mktemp -d)"; sp="$wd/system.md"
      { cat "$digest"; printf '\n\n%s\n' "$ROUTER_INSTRUCTION"; } > "$sp"
      echo "== router-eval: digest $digest · model $model · $(grep -c '' "$CASES") cases =="
      cmd="cd $(printf %q "$wd") && claude -p --model $(printf %q "$model") --setting-sources '' --tools '' --strict-mcp-config --no-session-persistence --max-budget-usd 0.25 --append-system-prompt \"\$(cat $(printf %q "$sp"))\""
    fi
    run score "$CASES" "$cmd" ;;
  *) run "$mode" "$CASES" ;;
esac
