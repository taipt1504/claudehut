#!/usr/bin/env python3
# hook-latency.py — the AC12 latency measurement behind evals/hook-bench.sh (05-hooks.md §11 AC12).
# AC12 is a BENCHMARK, not part of the gating hook-tests.sh: hook-bench.sh reports these numbers and gates them
# only under HOOK_BENCH_STRICT=1. `hook-bench.sh --self-test` points HOOK_TESTS_SCRIPTS_DIR at slowed scratch
# copies of the hooks and requires the verdict below to FAIL them.
#
# Usage: hook-latency.py <plugin-root> <plane> <plane-with-real-learnings> <plane-for-the-100-entry-store> <baseline.sh>
#   env HOOK_TESTS_SCRIPTS_DIR  measure the hooks in this dir instead of <plugin-root>/scripts
#   env HOOK_LAT_KEYS           comma list: measure only these probes (default: all four gated ones)
#   env HOOK_LAT_NO_REDO=1      no confirming re-measure of a failure (the self-test wants the raw verdict)
# Prints one JSON object: per probe {verdict, ok, gates…}, plus _meta.
#
# THE VERDICT. Fork/exec cost — what these hooks are made of — scales with machine load for the hook and for an
# independent baseline alike (bash start, read stdin, one jq, one test: the fixed cost every hook pays, and none
# of the hook code, so a regression in lib/hook-common.sh cannot hide in it). Every hook run is PAIRED with a
# baseline run on the same payload immediately before it. A probe passes only when ALL of these hold:
#   * normalized bound, per batch: hook wall p95 <= max(bound, bound x baseline p95 / REF_BASE_P95), median over
#     batches ("norm" = the p95 projected onto the reference machine = u x bound). REF_BASE_P95 = 8 ms is the
#     quiet-machine baseline p95 on the reference Mac. So the bound is the absolute one on a machine at least
#     that fast and RELAXES in proportion when the machine is measurably slower right now; it never tightens.
#   * per-hook ratio ceiling (V3-1): hook CPU time / baseline CPU time (median of each, per batch; median over
#     batches) <= CPU_CEIL[os][probe]. The normalized bound alone does not enforce AC12: it relaxes with the
#     baseline, so at load ~11 on 10 CPUs a +50 ms CPU regression in advise-write passed at p95 72 ms against a
#     relaxed 88 ms — a CPU regression can hide behind load at MODERATE load already, not only under heavy load.
#     CPU time, unlike wall time, barely moves with load (the run queue adds wall, not CPU), so a ratio of CPU
#     times is what the hook itself controls. The ceilings are calibrated per OS (see CPU_CEIL) with headroom
#     below 3x the healthiest ratio measured, so a 3x CPU regression fails at every load. The wall ratio r95 is
#     reported beside it but not gated (it moves with load).
#   * wait cap: a wait (sleep, lock wait, blocking I/O) adds wall time but no CPU time. The least OFF-CPU time of
#     any hook run minus that of any baseline run must be <= min(WAIT_CAP, WAIT_MS + the baseline p50).
#     Measured on the Mac at quiet load, load 24 and load 52-75: healthy hooks 0.3-35.5 ms (the 100-entry store
#     is the high one, under load), a `sleep 0.05` copy 53.2-101.8 ms.
#   * sanity: a hook run that exits non-zero fails the verdict (a missing script would otherwise be "fast").
#   * a probe that fails is re-measured once in a fresh interleaved attempt and fails only if that fails too.
import json, os, platform, random, resource, subprocess, sys, time

root, lp, lr, ls, base = sys.argv[1:6]
scripts = os.environ.get("HOOK_TESTS_SCRIPTS_DIR") or root + "/scripts"
keys = [k for k in os.environ.get("HOOK_LAT_KEYS", "").split(",") if k]

# The gated no-task store: 100 synthetic entries shaped like the real va-ms store (93 entries, ~335-char
# learnings, mixed case, 5 categories, 60 days of timestamps). Deterministic (seeded), so the gate does not
# depend on a machine-local file — and it exercises the whole inject-learnings pass, which an empty plane skips.
rnd = random.Random(12)
vocab = ("WebClient onErrorMap Mono Flux R2DBC Postgres replica Kafka listener idempotency ledger settlement "
         "display name filter support api dynamic view Gradle build error Liquibase changeSet UUID timestamp "
         "encoding transaction boundary retry backoff cache eviction").split()
with open(ls + "/.claude/claudehut/learnings.jsonl", "w") as f:
    for i in range(100):
        words = [rnd.choice(vocab) for _ in range(48)]
        f.write(json.dumps({"id": "L-%04d" % (i + 1), "ts": "2026-%02d-%02dT10:00:00Z" % (7 + i % 2, 1 + i % 28),
            "category": ["pitfall", "convention", "decision", "reuse", "finding"][i % 5],
            "trigger": "|".join(sorted({w.lower() for w in words[:5]})), "learning": " ".join(words)[:340],
            "evidence": "src/main/java/a/B%d.java:%d; C.java:12" % (i, i), "confidence": 0.5 + (i % 5) / 10,
            "hits": 1 + i % 4}) + "\n")

REF_BASE_P95 = 8.0; WAIT_MS = 25.0; WAIT_CAP = 45.0
BOUND = {"advise-write": 50, "inject-phase": 50, "inject-phase(100-entry store)": 50, "bootstrap": 300}
# CPU_CEIL: hook CPU / baseline CPU, healthy hooks, per-batch medians of 60-run batches, min-max over batches
# at load 5.9-7.4, and with 10 and 20 `yes` burners (load 20-41) on the Mac; docker ubuntu 24.04 non-root at
# quiet load and with 10 and 20 burners (2026-09-30):
#                     Darwin (M-series, 10 CPUs)   Linux (docker ubuntu)
#   advise-write      1.24-1.29                    1.48-2.04
#   inject-phase      1.71-1.79                    2.00-2.88
#   100-entry store   3.91-4.29                    5.97-7.75
#   bootstrap         2.75-3.29                    2.68-2.85
# (CPU time itself rose ~2.6x under the burners on the Mac — 4.2 → 11 ms for the baseline — the ratio did not.)
# Each ceiling sits >= 1.35x above the highest healthy ratio and below 3x the lowest, so noise passes and a
# 3x CPU regression fails at any load. ubuntu-latest was never measured (CI runs hook-bench.sh as a report, so
# it is not gated there); the report prints rc and the ceiling, which is what a recalibration needs.
CPU_CEIL = {
    "Darwin": {"advise-write": 2.0, "inject-phase": 2.7, "inject-phase(100-entry store)": 6.4, "bootstrap": 5.0},
    "Linux":  {"advise-write": 3.0, "inject-phase": 4.0, "inject-phase(100-entry store)": 11.0, "bootstrap": 4.5},
}
OS = platform.system()
CEIL = CPU_CEIL.get(OS, CPU_CEIL["Linux"])
env0 = dict(os.environ, CLAUDE_PLUGIN_ROOT=root); env0.pop("CLAUDE_ENV_FILE", None)
NCPU = os.cpu_count() or 1

class Probe:
    attempt = 0; rc_bad = set()
    def __init__(self, script, proj, payload, fresh=False, batches=3, n=60, warm=5):
        self.path = f"{scripts}/{script}.sh"
        self.payload, self.fresh, self.batches, self.n, self.warm = payload, fresh, batches, n, warm
        self.env = dict(env0, CLAUDE_PROJECT_DIR=proj); self.k = 0
        Probe.attempt += 1; self.ns = Probe.attempt   # a re-measure gets its own session ids: fresh stays fresh
    def pl(self):
        self.k += 1
        return self.payload.replace('"L"', '"L%d_%d"' % (self.ns, self.k)) if self.fresh else self.payload
    def run(self, path, pl):
        r0 = resource.getrusage(resource.RUSAGE_CHILDREN); t = time.perf_counter()
        rc = subprocess.run(["bash", path], input=pl.encode(), env=self.env,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode
        wall = (time.perf_counter() - t) * 1000; r1 = resource.getrusage(resource.RUSAGE_CHILDREN)
        if rc != 0: Probe.rc_bad.add("%s rc=%d" % (os.path.basename(path), rc))
        cpu = ((r1.ru_utime - r0.ru_utime) + (r1.ru_stime - r0.ru_stime)) * 1000
        return wall, wall - cpu, cpu
    def pair(self):
        pl = self.pl(); return self.run(base, pl), self.run(self.path, pl)
    def batch(self, bound):
        prs = [self.pair() for _ in range(self.n)]
        q = lambda v, f: sorted(v)[max(0, int(len(v) * f) - 1)]
        hw = [p[1][0] for p in prs]; bw = [p[0][0] for p in prs]
        hc = [p[1][2] for p in prs]; bc = [p[0][2] for p in prs]
        eff = max(bound, bound * q(bw, .95) / REF_BASE_P95)          # the bound, relaxed for a slow machine only
        return {"h50": q(hw, .5), "h95": q(hw, .95), "b50": q(bw, .5), "b95": q(bw, .95), "eff": eff,
                "u": q(hw, .95) / eff, "r95": q(hw, .95) / q(bw, .95),
                "hc50": q(hc, .5), "bc50": q(bc, .5), "rc": q(hc, .5) / max(q(bc, .5), 0.01),
                "wait": min(p[1][1] for p in prs) - min(p[0][1] for p in prs), "load": os.getloadavg()[0]}

def measure(probes):
    for p in probes.values():
        for _ in range(p.warm): p.pair()
    res = {k: [] for k in probes}
    for r in range(max(p.batches for p in probes.values())):     # round-robin: batch r of every hook, then r+1
        for k, p in probes.items():
            if r < p.batches: res[k].append(p.batch(BOUND[k]))
    med = lambda v: round(sorted(v)[len(v) // 2], 2)
    out = {}
    for k, v in res.items():
        o = {x: med([b[x] for b in v]) for x in ("h50", "h95", "b50", "b95", "eff", "u", "r95", "hc50", "bc50", "rc", "wait", "load")}
        o["wmax"] = round(min(WAIT_CAP, WAIT_MS + o["b50"]), 1)
        o["cmax"] = CEIL.get(k, 0)
        o["ok_work"] = o["u"] <= 1
        o["ok_cpu"] = o["cmax"] <= 0 or o["rc"] <= o["cmax"]
        o["ok_wait"] = o["wait"] <= o["wmax"]
        o["ok"] = o["ok_work"] and o["ok_cpu"] and o["ok_wait"]
        o["norm"] = round(o["u"] * BOUND[k], 1)
        o["batches"] = ["%.1f/%.0f" % (b["h95"], b["eff"]) for b in v]
        o["rcs"] = ["%.2f" % b["rc"] for b in v]
        out[k] = o
    return out

w = json.dumps({"session_id": "L", "tool_name": "Write", "tool_input": {"file_path": lp + "/src/main/java/A.java"}})
u = json.dumps({"session_id": "L", "prompt": "cần thêm filter support cho display name ở api dynamic va view"})
s = json.dumps({"session_id": "L", "source": "startup"})
def mk():
    d = {"advise-write": Probe("advise-write", lp, w), "inject-phase": Probe("inject-phase", lp, u),
         "inject-phase(100-entry store)": Probe("inject-phase", ls, u, fresh=True),
         "bootstrap": Probe("bootstrap", lp, s, batches=1)}
    return {k: v for k, v in d.items() if not keys or k in keys}
out = measure(mk())
redo = [] if os.environ.get("HOOK_LAT_NO_REDO") == "1" else [k for k in out if not out[k]["ok"]]
if redo:
    again = measure({k: v for k, v in mk().items() if k in redo})
    for k in redo:
        again[k]["first"] = {x: out[k][x] for x in ("u", "rc", "wait", "h95", "eff", "load", "batches")}
        out[k] = again[k]
for k, v in out.items():
    v["bound"] = BOUND[k]
    v["verdict"] = "pass" if v["ok"] and not Probe.rc_bad else "fail"
if not keys and os.path.exists(lr + "/.claude/claudehut/learnings.jsonl") and os.path.getsize(lr + "/.claude/claudehut/learnings.jsonl"):
    BOUND["inject-phase(va-ms learnings)"] = 50
    out.update(measure({"inject-phase(va-ms learnings)": Probe("inject-phase", lr, u, fresh=True)}))
    out["inject-phase(va-ms learnings)"]["bound"] = 50
# doclint-advise (M3): info probes, never gated and uncalibrated (no CPU ceiling) — a non-artifact .md (the
# in-script fast exit that the hooks.json if:*.md filter still lets through) and a plan.md with one blocking
# violation (the full engine). Only in a full run, like the va-ms probe, so --self-test / HOOK_LAT_KEYS skip it.
if not keys:
    ld = os.path.join(os.path.dirname(lp), "lat-doclint"); td = ld + "/.claude/claudehut/tasks/0001-x"
    os.makedirs(td, exist_ok=True)
    with open(ld + "/NOTES.md", "w") as f: f.write("# notes\n")
    with open(td + "/plan.md", "w") as f:
        f.write("# Plan: t\n> id: 0001-x · spec-rev: 1 · route: full · rev: 1 · status: draft\n\n## 1. Approach\nreuse.\n\n"
                "## 2. Design\n```java\nclass A {}\n```\n\n## 4. Tasks\n| ID | Goal | Files | Test first | Verify | Depends | Req |\n"
                "|---|---|---|---|---|---|---|\n| T1 | do it | a.java | FooTest#bar | gradle | - | AC-001 |\n")
    dp = lambda f: json.dumps({"session_id": "L", "hook_event_name": "PostToolUse", "tool_name": "Write", "tool_input": {"file_path": f}})
    info = {"doclint-advise(non-artifact .md)": Probe("doclint-advise", ld, dp(ld + "/NOTES.md")),
            "doclint-advise(plan.md)": Probe("doclint-advise", ld, dp(td + "/plan.md"))}
    for k in info: BOUND[k] = 150; CEIL[k] = 0
    out.update(measure(info))
    for k in info: out[k]["bound"] = BOUND[k]
out["_meta"] = {"ncpu": NCPU, "os": OS, "ref_base_p95": REF_BASE_P95, "wait_ms": WAIT_MS, "wait_cap": WAIT_CAP, "rc_bad": sorted(Probe.rc_bad)}
print(json.dumps(out))
