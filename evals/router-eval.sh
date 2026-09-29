#!/usr/bin/env bash
# Router eval harness for the v0.12 routing rubric (04-routing-harness.md §2: direct | light | full, plus
# `ask` when two adjacent routes are both reasonable). Cases: evals/router-cases.jsonl — real ewallet prompts,
# redacted, one expected route + one-line rationale each.
#
# M0 scope: schema validation and dry-run only. NO live model calls happen unless --model-cmd is given.
#
# Usage:
#   router-eval.sh [--cases FILE]                      # dry-run: print id, expected route, first prompt line
#   router-eval.sh --validate [--cases FILE]           # schema check; exit 1 on any error
#   router-eval.sh --model-cmd 'CMD' [--cases FILE]    # later milestones: CMD reads the prompt on stdin and
#                                                      # prints a route word; reports accuracy and the §5
#                                                      # invariant "0 full-labelled prompt routed to direct"
#   router-eval.sh --self-test                         # validator discriminates bad fixtures
#
# Case schema (one JSON object per line):
#   id (unique string) · source ("<service>/<session-prefix>") · prompt (non-empty) ·
#   expected_route in direct|light|full|ask · rationale (one line, <=300 chars) ·
#   candidates (ask ONLY: 2 distinct routes from direct|light|full, recommended first) · truncated (optional bool)
# Redaction guard: a prompt must not carry an absolute home path or a credential-looking assignment.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CASES="$ROOT/evals/router-cases.jsonl"

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
hit, full_to_direct, rows = 0, 0, []
for c in cases:
    try: out = subprocess.run(cmd, shell=True, input=c["prompt"], capture_output=True, text=True, timeout=300).stdout
    except subprocess.TimeoutExpired: out = ""
    m = re.search(r"\b(direct|light|full|ask)\b", out.lower()); got = m.group(1) if m else "none"
    ok = got == c["expected_route"]; hit += ok
    full_to_direct += c["expected_route"] == "full" and got == "direct"
    rows.append(f"  {'ok  ' if ok else 'MISS'} {c['id']} expected {c['expected_route']} got {got}")
print("\n".join(rows))
print(f"  accuracy {hit}/{len(cases)} · full->direct {full_to_direct} (invariant: 0)")
sys.exit(0 if full_to_direct == 0 else 1)
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
  chk "shipped router-cases.jsonl validates" 'run validate "$CASES" >/dev/null'
  rm -rf "$t"
  echo "  self-test: $pass passed, $fail failed"; [ "$fail" -eq 0 ]
}

mode=dryrun; cmd=""
while [ $# -gt 0 ]; do
  case "$1" in
    --validate) mode=validate ;;
    --self-test) mode=selftest ;;
    --cases) CASES="$2"; shift ;;
    --model-cmd) mode=score; cmd="$2"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done
case "$mode" in
  selftest) self_test ;;
  score) run score "$CASES" "$cmd" ;;
  *) run "$mode" "$CASES" ;;
esac
