#!/usr/bin/env python3
"""plugin-eval-signals.py — what each `claude plugin eval` run actually saw and did (M3c lesson).

`out/trace.jsonl` records only the SessionStart hook events; the context other hooks inject (UserPromptSubmit,
PreToolUse) lives in the run's session log `config/projects/*/*.jsonl`. Reading only the trace once produced a
wrong conclusion ("UserPromptSubmit does not fire under -p"), so signals are read from the session log.

Usage: python3 evals/plugin-eval-signals.py <results dir of a --keep-temp run> [--json]
Per run: case, arm, score, real kb tool_use calls (by tool), whether the variation hint (UserPromptSubmit) and the
write-time advisory (PreToolUse) were injected, and the files the agent wrote. Read-only.
"""
import glob
import json
import os
import sys

KB = "mcp__plugin_claudehut_kb__"
HINTS = ("kb: this repo already selects among variants", "Deliberation trigger (T2)")   # M3c wording, M4 wording
ADVISORY = "looks like a new variant"


def session_log(trace_path):
    root = os.path.dirname(os.path.dirname(trace_path))
    logs = glob.glob(os.path.join(root, "config", "projects", "*", "*.jsonl"))
    return logs[0] if logs else None


def signals(path):
    out = {"kb_calls": {}, "hint": False, "advisory": False, "writes": []}
    if not path:
        out["error"] = "no session log (run without --keep-temp, or cleaned)"
        return out
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if any(h in line for h in HINTS):
                out["hint"] = True
            if ADVISORY in line:
                out["advisory"] = True
            try:
                o = json.loads(line)
            except ValueError:
                continue
            msg = o.get("message") if isinstance(o, dict) else None
            if not isinstance(msg, dict) or o.get("type") != "assistant":
                continue
            for c in msg.get("content") or []:
                if isinstance(c, dict) and c.get("type") == "tool_use":
                    name = c.get("name", "")
                    if name.startswith(KB):
                        k = name[len(KB):]
                        out["kb_calls"][k] = out["kb_calls"].get(k, 0) + 1
                    if name == "Skill":
                        out.setdefault("skills", []).append((c.get("input") or {}).get("skill", ""))
                    if name in ("Write", "Edit"):
                        fp = (c.get("input") or {}).get("file_path", "")
                        out["writes"].append(f"{name}:{fp.split('/src/main/java/')[-1]}")
    return out


def main(argv):
    if not argv:
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        return 2
    agg = json.load(open(os.path.join(argv[0], "aggregate-result.json"), encoding="utf-8"))
    rows = []
    for case in agg.get("cases", []):
        for arm, runs in (case.get("arms") or {}).items():
            for i, run in enumerate(runs, 1):
                tp = run.get("tracePath") or ""
                rows.append(dict({"case": case["name"], "arm": arm, "run": i, "score": run.get("score")},
                                 **signals(session_log(tp) if tp else None)))
    if "--json" in argv:
        print(json.dumps(rows, ensure_ascii=False, indent=1))
        return 0
    for r in rows:
        kb = sum(r["kb_calls"].values())
        print(f"{r['case']:<32} {r['arm']:<7} #{r['run']} score={r['score']} kb_calls={kb} hint={int(r['hint'])} "
              f"advisory={int(r['advisory'])} skills={','.join(r.get('skills', [])) or '-'} writes={' '.join(r['writes'])[:120]}{(' ' + r['error']) if r.get('error') else ''}")
    n = len(rows) or 1
    print(f"-- {len(rows)} run(s): kb used in {sum(1 for r in rows if r['kb_calls'])}, hint in {sum(r['hint'] for r in rows)}, "
          f"advisory in {sum(r['advisory'] for r in rows)} ({100 * sum(1 for r in rows if r['kb_calls']) // n}% kb use)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
