#!/usr/bin/env python3
"""ClaudeHut kernel CLI. Entry points (shims in bin/):

  claudehut-verify claims <file.md>… [--project DIR] [--task DIR] [--json]
  claudehut-verify findings --task DIR [--evidence review.md] [--json]
  claudehut-verify verdict --task DIR [--json]
  claudehut-verify vendor-leak [PATH…] [--project DIR] [--json]   vendor names in neutral places (advisory sensor)
  claudehut-kernel gate review-pass --project DIR --task DIR --evidence FILE [--override TEXT]
  claudehut-kernel gate plan --project DIR --task DIR [--override R]   pack invariants at set-plan (default warn)
  claudehut-kernel gate end --project DIR --task DIR --status done|abandoned [--override TEXT]
  claudehut-kernel probe [--project DIR] [--write] [--advice]
  claudehut-kernel learn retract <id> --reason R [--hub DIR] | learn verify <id> --by X [--hub DIR]
  claudehut-run eval|mining|drift|propose [--auth plan|api|auto] [--dry-run] [--out DIR] [--json] …   (= claudehut-kernel run)
  claudehut-kernel profile [--level L0|L1|L2|L3] [--write SETTINGS.json]   K5 autonomy (printed unless --write)
  claudehut-kernel telemetry --task DIR… --out FILE   K9 bridge: GenAI-shaped spans, local file only
  claudehut-kernel campaign create|template|status|list|pending|mirror [<id>] [--hub H] …   K8 campaigns (04 §6)
  claudehut status [--project DIR] [--selftest] [--json] [--campaign ID]   (= claudehut-kernel status) K9 state surface, 08 §2
  claudehut-kernel selftest [--json]       liveness canaries for every hook and gate (exit 1 when one is dead)
  claudehut-kernel event --task DIR --type T [--data JSON]
  claudehut-kernel packs [--project DIR] [--json] [--owner PATH…]   K10: which packs are active for the project (and
                                                 why); --owner prints the pack owning each plugin-relative path
  claudehut-kernel dist --out DIR [--channel stable|canary]   M2b: build the split distribution (two directory
                                                 marketplaces) from the pack manifests; tracked files only
  claudehut-kernel replay --task DIR [--check]   project tasks/<id>/events.jsonl → the task record (K1); --check exits 1
                                                 when it differs from task.json (exit 0 with a note: no state events yet)

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

from claudehut_kernel import campaign, dist, events, gates, learn, packs, plane, probe, profile, runner, selftest, status, tasklog, telemetry, vendorleak, verify  # noqa: E402


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


def cmd_vendor_leak(a):
    project = _project(a)
    res = vendorleak.scan(project, a.paths)
    if a.json:
        print(json.dumps(res, ensure_ascii=False))
    else:
        for h in res["findings"]:
            print(f"vendor-leak: {h['file']}:{h['line']} {h['kind']} {h['text']} — {h['fix']}", file=sys.stderr)
        fam = "" if res["families"] == "ok" else " (index missing: only vendors.txt was used — run claudehut-index update)"
        print(f"vendor-leak: {len(res['vendors'])} vendor(s) known, {len(res['findings'])} finding(s){fam}",
              file=sys.stderr)
    return 1 if res["findings"] else 0


def cmd_gate(a):
    rc, out = gates.run(a.which, _project(a), os.path.abspath(a.task), evidence=a.evidence, status=a.status,
                        override=a.override, ts=_ts())
    if rc == 2:
        return 2
    print(json.dumps(out, ensure_ascii=False))
    return rc


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


def cmd_campaign(a):
    project = _project(a)
    hub = campaign.hub_of(project, a.hub)
    if a.action == "pending":   # SessionStart: one line or nothing, never an error
        try:
            line = campaign.pending_line(project) if hub else ""
        except (OSError, ValueError):
            line = ""
        if line:
            print(line)
        return 0
    if not hub:
        print("campaign: no hub (pass --hub, set CLAUDEHUT_HUB or topology.json .hub)", file=sys.stderr)
        return 2
    try:
        if a.action == "create":
            repos = [(r.split("=", 1)[0], r.split("=", 1)[1] if "=" in r else None) for r in a.repo or []]
            if not (a.id and a.goal and a.template and repos and a.owner):
                print("campaign create <id> --goal G --template PATH --repo NAME[=PATH]… --owner O", file=sys.stderr)
                return 2
            c = campaign.create(hub, a.id, a.goal, a.template, repos, a.owner)
            print(json.dumps(c, ensure_ascii=False))
        elif a.action == "template":
            c, moved = campaign.update_template(hub, a.id)
            print(f"campaign {a.id}: template {'moved to' if moved else 'unchanged at'} {c['template']['rev'][7:14]}",
                  file=sys.stderr)
        elif a.action == "status":
            ag = campaign.aggregate(hub, a.id)
            print(json.dumps(ag, ensure_ascii=False) if a.json else campaign.render(ag))
        elif a.action == "list":
            for c in campaign.campaigns(hub):
                print(f"{c['id']}: {c.get('goal')} ({len(c.get('repos') or [])} repos, owner {c.get('owner')})")
        elif a.action == "mirror":
            t = plane.load_task(os.path.abspath(a.task))
            n = campaign.mirror(hub, t["campaign_id"], t["campaign_repo"], os.path.abspath(a.task))
            print(f"campaign mirror: {n} event(s) appended", file=sys.stderr)
    except (ValueError, KeyError) as exc:
        print(f"campaign: {exc}", file=sys.stderr)
        return 1
    return 0


def cmd_run(a):
    rc, rep = runner.run(a.job, auth=a.auth, out=a.out, dry_run=a.dry_run, extra=a.rest, projects_dir=a.projects_dir,
                         since_days=a.since_days, summarize=a.summarize, projects=a.project)
    if a.json:
        print(json.dumps(rep, ensure_ascii=False))
    else:
        if rep.get("error"):
            print(f"claudehut-run: {rep['error']}", file=sys.stderr)
        else:
            print(f"claudehut-run {a.job}: auth {rep['auth_mode']}"
                  + (" (dry run)" if a.dry_run else f", report {rep.get('report')}"), file=sys.stderr)
    return rc


def cmd_profile(a):
    if a.level not in profile.LEVELS:
        for k, v in profile.LEVELS.items():
            print(f"{k}  {v['desc']}")
        return 0 if not a.level else 2
    if a.write:   # only when the user runs it: the harness issues no grants (K-08, HIL-3)
        cur = profile.merge_into(a.write, a.level)
        print(f"profile {a.level} merged into {a.write} (defaultMode {cur['permissions']['defaultMode']})",
              file=sys.stderr)
    else:
        print(json.dumps(profile.settings_for(a.level), indent=2))
        print(f"profile {a.level}: printed only. To apply it yourself: claudehut-kernel profile --level {a.level} "
              f"--write <settings.json>", file=sys.stderr)
    return 0


def cmd_telemetry(a):
    n = telemetry.export([os.path.abspath(t) for t in a.task], a.out)
    print(f"telemetry: {n} span(s) → {a.out} (local file; nothing sent)", file=sys.stderr)
    return 0


def cmd_status(a):
    project = _project(a)
    if a.campaign:
        a.action, a.id, a.hub = "status", a.campaign, None
        return cmd_campaign(a)
    res = None
    if a.selftest:
        res = selftest.run(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    st = status.collect(project, res)
    print(json.dumps(st, ensure_ascii=False) if a.json else status.render(st))
    return 1 if st.get("sensors", {}).get("dead") else 0


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


def cmd_packs(a):
    manifests, errors = packs.load()
    if a.owner:
        rows = {p: packs.owners_of(p, manifests) for p in a.owner}
        print(json.dumps(rows, ensure_ascii=False))
        return 0 if all(len(v) == 1 for v in rows.values()) else 1
    manifests, errors, reg = packs.load_all(_project(a))
    res = packs.evaluate(_project(a), manifests)
    for r in res:
        r["registration"] = reg.get(r["pack"], "unregistered")
    res += [{"pack": n, "active": False, "why": "registered root or manifest is gone", "registration": st}
            for n, st in sorted(reg.items()) if n not in manifests]
    if a.json:
        print(json.dumps({"packs": res, "errors": errors}, ensure_ascii=False))
    else:
        for r in res:
            print(f"{'on ' if r['active'] else 'off'}  {r['pack']:<20} {r['registration']:<12} {r['why']}")
        for e in errors:
            print(f"ERR  {e['pack']:<20} {e['error']}", file=sys.stderr)
    return 1 if errors else 0


def cmd_dist(a):
    try:
        rep = dist.build(os.path.abspath(a.out), a.channel)
    except RuntimeError as exc:
        print(f"dist: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(rep, ensure_ascii=False))
    return 0


def cmd_replay(a):
    task_dir = os.path.abspath(a.task)
    proj, rev = tasklog.project(events.read(task_dir))
    if proj is None:
        print(f"replay: {task_dir}/events.jsonl holds no state event yet (a 0.12 task: imported on its next write)",
              file=sys.stderr)
        return 0
    if not a.check:
        print(json.dumps(proj, ensure_ascii=False, indent=1))
        return 0
    cur = plane.read_json(os.path.join(task_dir, "task.json"))
    if proj == cur:
        print(f"replay: rev {rev} reproduces task.json", file=sys.stderr)
        return 0
    keys = sorted(k for k in set(proj) | set(cur or {}) if (cur or {}).get(k) != proj.get(k))
    print(f"replay: rev {rev} differs from task.json in: {', '.join(keys)}", file=sys.stderr)
    return 1


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
    vl = vs.add_parser("vendor-leak")
    vl.add_argument("paths", nargs="*")
    vl.add_argument("--project")
    vl.add_argument("--json", action="store_true")
    vl.set_defaults(fn=cmd_vendor_leak)

    g = sub.add_parser("gate")
    g.add_argument("which", choices=["review-pass", "end", "plan"])
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

    su = sub.add_parser("status")
    su.add_argument("--project")
    su.add_argument("--selftest", action="store_true", help="also run every canary (each hook runs once)")
    su.add_argument("--json", action="store_true")
    su.add_argument("--campaign", help="the campaign's aggregate instead (repos done / in progress / blocked …)")
    su.set_defaults(fn=cmd_status)

    rn = sub.add_parser("run", help="claudehut-run: offline jobs (eval | mining | drift | propose), read-only, report only")
    rn.add_argument("job", choices=["eval", "mining", "drift", "propose"])
    rn.add_argument("--auth", default="auto", choices=["plan", "api", "auto"])
    rn.add_argument("--out", help="report dir (default: a temp dir; never a repo)")
    rn.add_argument("--dry-run", action="store_true", help="resolve auth and print the command; run and write nothing")
    rn.add_argument("--projects-dir", help="mining/propose: transcripts root (default ~/.claude/projects)")
    rn.add_argument("--since-days", type=float)
    rn.add_argument("--summarize", action="store_true", help="mining: ask the model about the counts")
    rn.add_argument("--project", action="append", help="drift: a project dir (repeat)")
    rn.add_argument("--json", action="store_true")
    rn.set_defaults(rest=[])   # eval: everything after `--` goes to evals/plugin-eval.sh
    rn.set_defaults(fn=cmd_run)

    pf = sub.add_parser("profile", help="K5 autonomy L0-L3 → permission settings (printed; --write only on request)")
    pf.add_argument("--level")
    pf.add_argument("--write", help="a settings JSON file to merge the level into")
    pf.set_defaults(fn=cmd_profile)

    tl = sub.add_parser("telemetry", help="K9: task event logs → GenAI-shaped spans in a local file")
    tl.add_argument("--task", action="append", required=True)
    tl.add_argument("--out", required=True)
    tl.set_defaults(fn=cmd_telemetry)

    cp = sub.add_parser("campaign")
    cp.add_argument("action", choices=["create", "template", "status", "list", "pending", "mirror"])
    cp.add_argument("id", nargs="?")
    cp.add_argument("--project")
    cp.add_argument("--hub")
    cp.add_argument("--goal")
    cp.add_argument("--template", help="a file under the hub root, referenced (never copied) by every child task")
    cp.add_argument("--repo", action="append", help="NAME or NAME=PATH, in rollout order (repeat)")
    cp.add_argument("--owner")
    cp.add_argument("--task", help="mirror: the child task dir")
    cp.add_argument("--json", action="store_true")
    cp.set_defaults(fn=cmd_campaign)

    st = sub.add_parser("selftest")
    st.add_argument("--json", action="store_true")
    st.set_defaults(fn=cmd_selftest)

    e = sub.add_parser("event")
    e.add_argument("--task", required=True)
    e.add_argument("--type", required=True)
    e.add_argument("--data")
    e.add_argument("--source", default="cli")
    e.set_defaults(fn=cmd_event)

    pk = sub.add_parser("packs")
    pk.add_argument("--project")
    pk.add_argument("--json", action="store_true")
    pk.add_argument("--owner", nargs="+")
    pk.set_defaults(fn=cmd_packs)

    ds = sub.add_parser("dist")
    ds.add_argument("--out", required=True)
    ds.add_argument("--channel", default="stable", choices=["stable", "canary"])
    ds.set_defaults(fn=cmd_dist)

    rp = sub.add_parser("replay")
    rp.add_argument("--task", required=True)
    rp.add_argument("--check", action="store_true")
    rp.set_defaults(fn=cmd_replay)

    rest = []
    if argv[:1] == ["run"] and "--" in argv:   # `claudehut-run eval … -- <plugin-eval.sh args>` pass through verbatim
        i = argv.index("--")
        argv, rest = argv[:i], argv[i + 1:]
    a = ap.parse_args(argv)
    if a.cmd == "run":
        a.rest = list(a.rest or []) + rest
    return a.fn(a)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except SystemExit:
        raise
    except Exception as exc:  # a kernel crash must never read as "refused" (1): 3 = unavailable
        print(f"claudehut-kernel: internal error: {type(exc).__name__}: {exc}", file=sys.stderr)
        sys.exit(3)
