#!/usr/bin/env bash
# hook-bench.sh — the AC12 hook latency BENCHMARK (05-hooks.md §11 AC12). Not part of the gating hook-tests.sh:
# wall-clock latency depends on the machine and its load, so a red CI run here would say more about the runner
# than about the hooks. The measurement and its verdict live in evals/lib/hook-latency.py.
#
# Run: evals/hook-bench.sh                     report per probe: p95, baseline p95, the baseline-normalized p95
#                                              vs its bound, the per-hook CPU ratio vs its ceiling, the off-CPU
#                                              wait; exit 0 whatever the numbers
#      HOOK_BENCH_STRICT=1 evals/hook-bench.sh opt-in gate: every probe must hold BOTH the normalized bound AND
#                                              its per-hook ratio ceiling (and the wait cap), and a 3x-CPU and a
#                                              50 ms-sleep copy of advise-write must FAIL that verdict (V3-1)
#      evals/hook-bench.sh --self-test [--keys k1,k2]
#                                              prove the strict verdict FAILS slowed copies: for each probe a copy
#                                              that burns +2x its own CPU (a 3x regression) and one that sleeps
#                                              50 ms first. Default keys: all four. Run it at the load you want to
#                                              prove (quiet, and e.g. with NCPU `yes` burners).
#
# Reading the verdict (M1 backlog):
#   * The load-normalized bound relaxes with the baseline, so under load it passes a hook that got slower (a 50 ms-
#     sleep copy measured "normalized true" at load ~8-10). Treat it as informational there: the per-hook CPU ratio
#     and the off-CPU wait gates are what catch a slowdown under load, and the strict self-test proves both.
#   * CPU_CEIL (evals/lib/hook-latency.py) is calibrated on Darwin; the Linux column comes from a docker ubuntu and
#     was never re-measured on a CI ubuntu-latest runner. Harmless while CI runs report-only; calibrate it there
#     before anyone turns HOOK_BENCH_STRICT=1 on for Linux.
#   * A probe with no ratio ceiling (the machine-local va-ms info probe, the two doclint-advise info probes, the
#     inject-phase/bootstrap probes on a 1000-file index/files.json + meta.json plane, the four hint-explore probes
#     (Read and Grep) on a microservice plane with an 80 KB tool_response — AC-11 p95 ≤30 ms) prints "vs ceiling n/a".
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY="$ROOT/evals/lib/hook-latency.py"
KEYS="advise-write,inject-phase,inject-phase(100-entry store),bootstrap"; SELF=0
while [ $# -gt 0 ]; do
  case "$1" in
    --self-test) SELF=1; shift ;;
    --keys) KEYS="$2"; shift 2 ;;
    *) echo "usage: $0 [--self-test [--keys k1,k2]]" >&2; exit 2 ;;
  esac
done
STRICT="${HOOK_BENCH_STRICT:-0}"
if ! command -v python3 >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "hook-bench: python3 and jq required — skipped"; [ "$STRICT" = 1 ] || [ "$SELF" = 1 ] && exit 1; exit 0
fi
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
for d in lat lat-real lat-store; do mkdir -p "$W/$d/.claude/claudehut"; done
REAL_SRC="$HOME/Documents/Projects/ewallet-workspace/va-ms/.claude/claudehut/learnings.jsonl"
[ "$SELF" = 1 ] || { [ -f "$REAL_SRC" ] && cp "$REAL_SRC" "$W/lat-real/.claude/claudehut/learnings.jsonl"; }
# The baseline is the fixed cost EVERY hook pays and nothing more — bash start, read stdin, one jq, one test —
# and it is independent of the hook code, so a regression in lib/hook-common.sh cannot hide in it.
printf '%s\n' 'x="$(cat)"; jq -r .session_id <<<"$x" >/dev/null 2>&1; [ -d "$CLAUDE_PROJECT_DIR/.claude/claudehut" ]; exit 0' > "$W/b.sh"
lat() { # $1 scripts dir  $2 keys ("" = all)  $3 no-redo (1/0) → the JSON
  HOOK_TESTS_SCRIPTS_DIR="$1" HOOK_LAT_KEYS="$2" HOOK_LAT_NO_REDO="$3" CLAUDE_PLUGIN_ROOT="$ROOT" \
    python3 "$PY" "$ROOT" "$W/lat" "$W/lat-real" "$W/lat-store" "$W/b.sh"
}
jk() { jq -r --arg k "$2" ".[\$k].$3" <<<"$1"; }   # $1 json  $2 key  $3 field

# --- self-test: the strict verdict must FAIL slowed copies (folded in from the former ac12-sensitivity.sh) ---
script_of() { case "$1" in inject-phase*) echo inject-phase ;; *) echo "$1" ;; esac; }
copy() { mkdir -p "$W/$1"; cp -R "$ROOT/scripts/." "$W/$1/"; }
inject() { # $1 file  $2 line inserted right after the shebang
  { head -1 "$1"; printf '%s\n' "$2"; tail -n +2 "$1"; } > "$1.new" && mv "$1.new" "$1" && chmod +x "$1"
}
self_test() { # $1 keys  $2 optional "key=ms" lines: CPU p50 of the unmodified hooks, measured by the caller
  local HCL="${2:-}" need="" k v d hk it f J MSI
  hc_of() { printf '%s\n' "$HCL" | awk -v k="$1" 'index($0, k"=")==1 { print substr($0, length(k)+2); exit }'; }
  IFS=, read -ra KA <<<"$1"
  for k in "${KA[@]}"; do [ -n "$(hc_of "$k")" ] || need="$need${need:+,}$k"; done
  # Control on an unmodified copy, unless the caller already measured it: a FAIL below is then the modification.
  if [ -n "$need" ]; then
    copy ctl; J="$(lat "$W/ctl" "$need" 1)"
    IFS=, read -ra NA <<<"$need"
    for k in "${NA[@]}"; do
      if [ "$(jk "$J" "$k" verdict)" = pass ]; then ok "control: unmodified $k passes (CPU ratio $(jk "$J" "$k" rc), p95 $(jk "$J" "$k" h95) ms)"
      else bad "control: unmodified $k FAILS here — the machine, not a regression; nothing below proves anything"; fi
      HCL="$HCL
$k=$(jk "$J" "$k" hc50)"
    done
  fi
  # CPU cost of one iteration of the busy loop, measured now (the same load as the probes).
  MSI="$(python3 - <<'PYL'
import resource, subprocess
n = 200000; best = None
for _ in range(3):
    r0 = resource.getrusage(resource.RUSAGE_CHILDREN)
    subprocess.run(["bash", "-c", "for ((_i=0;_i<%d;_i++)); do :; done" % n])
    r1 = resource.getrusage(resource.RUSAGE_CHILDREN)
    ms = ((r1.ru_utime - r0.ru_utime) + (r1.ru_stime - r0.ru_stime)) * 1000
    best = ms if best is None else min(best, ms)
print("%.9f" % (best / n))
PYL
)"
  for k in "${KA[@]}"; do
    d="cpu3x-$(script_of "$k")-$RANDOM"; copy "$d"
    hk="$(hc_of "$k")"; it="$(python3 -c "print(max(1, round(2 * $hk / $MSI)))")"
    inject "$W/$d/$(script_of "$k").sh" "for ((_ac12=0;_ac12<$it;_ac12++)); do :; done   # AC12 self-test: +2x CPU"
    J="$(lat "$W/$d" "$k" 1)"
    v="CPU ratio $(jk "$J" "$k" rc) vs ceiling $(jk "$J" "$k" cmax), p95 $(jk "$J" "$k" h95) ms vs $(jk "$J" "$k" eff) ms"
    if [ "$(jk "$J" "$k" verdict)" = fail ]; then ok "cpu3x: $k with +2x its own CPU ($hk ms → +$it loop iterations) FAILS — $v"
    else bad "cpu3x: $k with +2x its own CPU PASSES the verdict — $v"; fi
  done
  copy sleep
  for k in "${KA[@]}"; do
    f="$W/sleep/$(script_of "$k").sh"; grep -q 'AC12 self-test: sleep' "$f" || inject "$f" 'sleep 0.05   # AC12 self-test: sleep'
  done
  J="$(lat "$W/sleep" "$1" 1)"
  for k in "${KA[@]}"; do
    v="off-CPU $(jk "$J" "$k" wait) ms vs ≤$(jk "$J" "$k" wmax), p95 $(jk "$J" "$k" h95) ms"
    if [ "$(jk "$J" "$k" verdict)" = fail ]; then ok "sleep: $k with a 50 ms sleep FAILS — $v"
    else bad "sleep: $k with a 50 ms sleep PASSES the verdict — $v"; fi
  done
}

if [ "$SELF" = 1 ]; then
  echo "== AC12 self-test (load $(uptime | sed 's/.*averages*: //'), $(uname -s)) =="
  self_test "$KEYS"
  echo; echo "HOOK-BENCH SELF-TEST: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]; exit
fi

echo "== AC12 benchmark ($([ "$STRICT" = 1 ] && echo "STRICT: gated" || echo "report only; HOOK_BENCH_STRICT=1 gates it")) =="
LAT="$(lat "$ROOT/scripts" "" 0)"
echo "$LAT" | jq -r 'to_entries[] | select(.key != "_meta") | .value as $v
  | "  \(.key): p95 \($v.h95) ms (p50 \($v.h50)), baseline p95 \($v.b95) ms, wall ratio \($v.r95)x\n"
  + "      normalized p95 \($v.norm) ms vs bound \($v.bound // "-") ms (relaxed bound \($v.eff) ms; batches p95/bound \($v.batches|join(" ")))\n"
  + "      CPU ratio hook/baseline \($v.rc)x vs ceiling \(if ($v.cmax // 0) > 0 then $v.cmax else "n/a" end) (batches \($v.rcs|join(" "))); off-CPU over baseline \($v.wait) ms vs ≤\($v.wmax); load \($v.load)"
  + (if $v.first then "\n      RE-MEASURED, first attempt: p95 \($v.first.h95) ms vs \($v.first.eff) ms, CPU \($v.first.rc)x, off-CPU \($v.first.wait) ms, load \($v.first.load)" else "" end)'
echo "  (load = median 1-min load average over the batches, on $(jq -r '._meta.ncpu' <<<"$LAT") CPUs, $(jq -r '._meta.os' <<<"$LAT"); reference baseline p95 $(jq -r '._meta.ref_base_p95' <<<"$LAT") ms)"
jq -e '._meta.rc_bad == []' <<<"$LAT" >/dev/null || echo "  hook runs that exited non-zero: $(jq -r '._meta.rc_bad | join(", ")' <<<"$LAT")"
for k in advise-write inject-phase "inject-phase(100-entry store)" bootstrap; do
  gates="normalized $(jk "$LAT" "$k" ok_work), ratio $(jk "$LAT" "$k" ok_cpu), wait $(jk "$LAT" "$k" ok_wait)"
  if [ "$(jk "$LAT" "$k" verdict)" = pass ]; then ok "AC12: $k within its bound and ratio ceiling ($gates)"
  elif [ "$STRICT" = 1 ]; then bad "AC12 (strict): $k over its bound or ratio ceiling ($gates), confirmed by a re-measure"
  else echo "  WARN - AC12: $k over its bound or ratio ceiling on this machine right now ($gates; not gated)"; fi
done
if jq -e 'has("inject-phase(va-ms learnings)")' <<<"$LAT" >/dev/null; then
  echo "  info - real va-ms learnings store: within bound and ceiling = $(jk "$LAT" "inject-phase(va-ms learnings)" ok) (machine-local, never gated; the 100-entry synthetic store is the gated probe)"
fi
for k in "doclint-advise(non-artifact .md)" "doclint-advise(plan.md)" "inject-phase(1000-file index)" "bootstrap(1000-file index)" \
         "hint-explore(sibling Read, 80 KB response)" "hint-explore(in-project Read, 80 KB response)" \
         "hint-explore(Grep naming a sibling, 80 KB response)" "hint-explore(Grep escaped regex naming none, 80 KB response)"; do
  jq -e --arg k "$k" 'has($k)' <<<"$LAT" >/dev/null && echo "  info - $k: p95 $(jk "$LAT" "$k" h95) ms, p50 $(jk "$LAT" "$k" h50) ms, CPU ratio $(jk "$LAT" "$k" rc)x (never gated, no ceiling calibrated)"
done
if [ "$STRICT" = 1 ]; then
  # A strict verdict that stopped catching a regression would be a green light for nothing: prove it on
  # advise-write, sized from the measurement above (--self-test proves all four probes).
  self_test advise-write "advise-write=$(jk "$LAT" advise-write hc50)"
fi
echo; echo "HOOK-BENCH: $PASS ok, $FAIL failed$([ "$STRICT" = 1 ] || echo " (report only)")"
[ "$STRICT" != 1 ] || [ "$FAIL" -eq 0 ]
