#!/usr/bin/env python3
"""ClaudeHut kernel CLI. Entry points (shims in bin/):

  claudehut-verify claims <file.md>… [--project DIR] [--task DIR] [--json]
  claudehut-verify findings --task DIR [--evidence review.md] [--json]
  claudehut-verify verdict --task DIR [--json]
  claudehut-kernel gate review-pass --project DIR --task DIR --evidence FILE [--override TEXT]
  claudehut-kernel gate end --project DIR --task DIR --status done|abandoned [--override TEXT]
  claudehut-kernel probe [--project DIR] [--write] [--advice]
  claudehut-kernel learn retract <id> --reason R [--hub DIR] | learn verify <id> --by X [--hub DIR]
  claudehut-kernel selftest [--json]       liveness canaries for every hook and gate (exit 1 when one is dead)
  claudehut-kernel event --task DIR --type T [--data JSON]

Exit codes: 0 ok (pass or warn), 1 problems found (verify) / transition refused (gate), 2 usage error.
`gate` prints one JSON object on stdout for the bash state CLI and human lines on stderr.
"""
import sys

sys.dont_write_bytecode = True  # never write __pycache__ into the plugin dir, whatever the interpreter flags

import argparse  # noqa: E402
import json  # noqa: E402
import os  # noqa: E402
import time  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from claudehut_kernel import events, gates, learn, plane, probe, selftest, verify  # noqa: E402


def _project(a):
    return os.path.abspath(a.project or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd())


def _ts():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _human(problems, prefix):
    for p in problems:
        where = p.get("at") or ""
        what = p.get("path") or p.get("row") or ", ".join(map(str, p.get("items") or p.get("repos") or []))
        print(f"{prefix}: {p['kind']}{(' ' + where) if where else ''}{(' — ' + what) if what else ''}. {p.get('fix', '')}",
              file=sys.stderr)


def cmd_claims(a):
    project = _project(a)
    task = plane.load_task(a.task) if a.task else {}
    repos = plane.repo_dirs(project, task) if task else [(".", project)]
    total, problems = 0, []
    for md in a.files:
        n, pr = verify.check_claims(md, project, repos, task.get("base") or {})
        total += n
        problems += pr
    if a.json:
        print(json.dumps({"checked": total, "problems": problems}, ensure_ascii=False))
    else:
        _human(problems, "claims")
        print(f"claims: {total} checked, {len(problems)} problem(s)", file=sys.stderr)
    return 1 if problems else 0


def cmd_findings(a):
    task = plane.load_task(a.task)
    problems = verify.check_findings(task, a.evidence)
    if a.json:
        print(json.dumps({"problems": problems}, ensure_ascii=False))
    else:
        _human(problems, "findings")
    return 1 if problems else 0


def cmd_verdict(a):
    project = _project(a)
    problems = verify.check_verdict(project, plane.load_task(a.task))
    if a.json:
        print(json.dumps({"problems": problems}, ensure_ascii=False))
    else:
        _human(problems, "verdict")
    return 1 if problems else 0


def cmd_gate(a):
    project = _project(a)
    task_dir = os.path.abspath(a.task)
    task = plane.load_task(task_dir)
    out = {}
    if a.which == "review-pass":
        ev = plane.abspath(project, a.evidence)
        _, claim_problems = verify.check_claims(ev, project, plane.repo_dirs(project, task), task.get("base") or {})
        violations = [dict(p, invariant="review.claims-resolve") for p in claim_problems]
        violations += [dict(p, invariant="review.no-open-findings") for p in verify.check_findings(task, ev)]
        d = gates.decide(project, task_dir, "review-pass", violations, a.override)
        if d["decision"] != "block":
            out["binding"] = verify.binding(project, task, _ts())
            events.append(task_dir, "review.verdict", {"verdict": "pass", "evidence": a.evidence,
                                                       "gate": d["decision"]})
    elif a.which == "end":
        violations = []
        if a.status == "done":
            review = task.get("review") or "pending"
            if review not in ("pass", "capped"):
                violations.append({"kind": "review-not-done", "invariant": "end.done-requires-review",
                                   "fix": f"review is '{review}': run the review and `claudehut-state set-review pass "
                                          f"--evidence …`, or end with --status abandoned, or pass --override \"<reason>\"."})
            elif review == "pass":
                violations += [dict(p, invariant="end.verdict-current") for p in verify.check_verdict(project, task)]
        d = gates.decide(project, task_dir, "end", violations, a.override)
        if d["decision"] != "block":
            events.append(task_dir, "task.ended", {"status": a.status, "gate": d["decision"]})
    else:
        print(f"unknown gate {a.which}", file=sys.stderr)
        return 2
    out.update(d)
    if d["violations"]:
        label = {"warn": "WARN (gate mode warn, recorded)", "override": "OVERRIDDEN (recorded)",
                 "block": "BLOCKED"}[d["decision"]]
        _human(d["violations"], f"gate {a.which} {label}")
    print(json.dumps(out, ensure_ascii=False))
    return 1 if d["decision"] == "block" else 0


def cmd_probe(a):
    project = _project(a)
    if a.cached:  # SessionStart path: read the profile the async probe wrote, run nothing
        prof = plane.read_json(os.path.join(plane.plane_dir(project), "state", "env-profile.json"), {}) or {}
        line = probe.advice(prof) if a.advice else ""
        if line:
            print(line)
        elif not a.advice:
            print(json.dumps(prof, ensure_ascii=False))
        return 0
    execute = os.environ.get("CLAUDEHUT_PROBE_HOOKS", "1") != "0"
    prof = probe.probe(project, execute=execute)
    if a.write:
        st = os.path.join(plane.plane_dir(project), "state")
        if os.path.isdir(plane.plane_dir(project)):
            os.makedirs(st, exist_ok=True)
            tmp = os.path.join(st, "env-profile.json.tmp")
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(prof, f, ensure_ascii=False, indent=1)
            os.replace(tmp, os.path.join(st, "env-profile.json"))
    if a.advice:
        line = probe.advice(prof)
        if line:
            print(line)
    else:
        print(json.dumps(prof, ensure_ascii=False))
    return 0


def cmd_learn(a):
    project = _project(a)
    path = learn.store_path(project, a.hub)
    if a.action == "retract":
        if not a.reason:
            print("learn retract needs --reason", file=sys.stderr)
            return 2
        fields = {"status": "retracted", "retracted_reason": a.reason, "retracted_at": learn.now()}
    else:
        if not a.by:
            print("learn verify needs --by <test|commit|source file>", file=sys.stderr)
            return 2
        fields = {"verified_by": a.by, "verified_at": learn.now()}
    try:
        hit = learn.update(path, a.id, fields)
    except learn.LockError as e:
        print(f"learn {a.action}: {e}", file=sys.stderr)
        return 1
    if hit is None:
        print(f"learn {a.action}: {a.id} not found in {path}", file=sys.stderr)
        return 1
    print(json.dumps({"store": path, "entry": hit}, ensure_ascii=False))
    return 0


def cmd_selftest(a):
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    res = selftest.run(root)
    dead = [r for r in res if not r["ok"]]
    if a.json:
        print(json.dumps({"controls": len(res), "dead": len(dead), "results": res}, ensure_ascii=False))
    else:
        for r in res:
            print(f"{'ok  ' if r['ok'] else 'DEAD'} {r['control']}{('  — ' + r['why']) if r['why'] else ''}")
        print(f"selftest: {len(res) - len(dead)}/{len(res)} controls alive")
    return 1 if dead else 0


def cmd_event(a):
    data = json.loads(a.data) if a.data else None
    return 0 if events.append(os.path.abspath(a.task), a.type, data, source=a.source) else 1


def main(argv):
    ap = argparse.ArgumentParser(prog="claudehut-kernel")
    sub = ap.add_subparsers(dest="cmd", required=True)

    v = sub.add_parser("verify")
    vs = v.add_subparsers(dest="what", required=True)
    c = vs.add_parser("claims")
    c.add_argument("files", nargs="+")
    c.add_argument("--project")
    c.add_argument("--task")
    c.add_argument("--json", action="store_true")
    c.set_defaults(fn=cmd_claims)
    f = vs.add_parser("findings")
    f.add_argument("--task", required=True)
    f.add_argument("--evidence")
    f.add_argument("--json", action="store_true")
    f.set_defaults(fn=cmd_findings)
    r = vs.add_parser("verdict")
    r.add_argument("--task", required=True)
    r.add_argument("--project")
    r.add_argument("--json", action="store_true")
    r.set_defaults(fn=cmd_verdict)

    g = sub.add_parser("gate")
    g.add_argument("which", choices=["review-pass", "end"])
    g.add_argument("--project")
    g.add_argument("--task", required=True)
    g.add_argument("--evidence")
    g.add_argument("--status", default="done")
    g.add_argument("--override")
    g.set_defaults(fn=cmd_gate)

    pr = sub.add_parser("probe")
    pr.add_argument("--project")
    pr.add_argument("--write", action="store_true", help="write <plane>/state/env-profile.json")
    pr.add_argument("--advice", action="store_true", help="print only the SessionStart advisory line (or nothing)")
    pr.add_argument("--cached", action="store_true", help="read <plane>/state/env-profile.json, execute nothing")
    pr.set_defaults(fn=cmd_probe)

    ln = sub.add_parser("learn")
    ln.add_argument("action", choices=["retract", "verify"])
    ln.add_argument("id")
    ln.add_argument("--reason")
    ln.add_argument("--by")
    ln.add_argument("--hub", help="hub dir: act on its fleet-learnings.jsonl instead of the plane store")
    ln.add_argument("--project")
    ln.set_defaults(fn=cmd_learn)

    st = sub.add_parser("selftest")
    st.add_argument("--json", action="store_true")
    st.set_defaults(fn=cmd_selftest)

    e = sub.add_parser("event")
    e.add_argument("--task", required=True)
    e.add_argument("--type", required=True)
    e.add_argument("--data")
    e.add_argument("--source", default="cli")
    e.set_defaults(fn=cmd_event)

    a = ap.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except SystemExit:
        raise
    except Exception as exc:  # a kernel crash must never read as "refused" (1): 3 = unavailable
        print(f"claudehut-kernel: internal error: {type(exc).__name__}: {exc}", file=sys.stderr)
        sys.exit(3)
