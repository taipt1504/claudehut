"""`claudehut status` (K9, docs/v0.20 08 §2, DX-2): one read-only surface for the questions users ask by hand —
is a workflow stuck, is the index fresh, which packs run, is every control alive, which host mode.

Sources, all local and already written by other parts: pack manifests + the registry (K10), task projections and
event logs (K1), index/meta.json (K6), the hub's services.json, state/env-profile.json (K5 probe), and the selftest
canaries (K7, only with --selftest: it runs every hook once). Nothing here reads host internals, so whether the
running session is older than the installed plugin is `unknown`, never guessed.

TTL (04 §1, STA-2): an active task with no event for `topology.json .ttl_days` days (default 7) is reported stale.
"""
import calendar
import json
import os
import subprocess
import time

from . import campaign, packs, plane

TTL_DAYS = 7


def _ts(s):
    try:
        return calendar.timegm(time.strptime(s, "%Y-%m-%dT%H:%M:%SZ"))
    except (TypeError, ValueError):
        return None


def _age(sec):
    if sec is None:
        return "unknown"
    for unit, n in (("d", 86400), ("h", 3600), ("m", 60)):
        if sec >= n:
            return f"{int(sec // n)}{unit}"
    return f"{int(sec)}s"


def _git(project, *args):
    try:
        p = subprocess.run(["git", "-C", project, *args], capture_output=True, text=True, timeout=10)
        return p.stdout.strip() if p.returncode == 0 else ""
    except (OSError, subprocess.TimeoutExpired):
        return ""


def last_event_ts(task_dir, task):
    """The newest event's ts (the Python writer's log); the bash writer keeps no log, so task.json .updated."""
    last = None
    try:
        with open(os.path.join(task_dir, "events.jsonl"), encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    try:
                        last = json.loads(line).get("ts") or last
                    except ValueError:
                        pass
    except OSError:
        pass
    return last or task.get("updated") or task.get("created")


def tasks(project, now=None):
    now = now or time.time()
    ttl = plane.topology(project).get("ttl_days")
    ttl = ttl if isinstance(ttl, (int, float)) and ttl > 0 else TTL_DAYS
    td = os.path.join(plane.plane_dir(project), "tasks")
    out = []
    for d in sorted(os.listdir(td)) if os.path.isdir(td) else []:
        t = plane.load_task(os.path.join(td, d))
        if t.get("status") != "active":
            continue
        ts = last_event_ts(os.path.join(td, d), t)
        sec = now - _ts(ts) if _ts(ts) is not None else None
        out.append({"id": t.get("id") or d, "phase": t.get("phase"), "route": t.get("route"), "tier": t.get("tier"),
                    "review": t.get("review"), "campaign": t.get("campaign_id"), "last_event": ts,
                    "age": _age(sec), "stale": sec is not None and sec > ttl * 86400})
    return out, ttl


def knowledge(project):
    pd = plane.plane_dir(project)
    meta = plane.read_json(os.path.join(pd, "index", "meta.json"), {}) or {}
    head = _git(project, "rev-parse", "HEAD")
    ic = meta.get("indexed_commit")
    idx = {"indexed_commit": ic, "head": head or None,
           "state": "none" if not ic else ("current" if ic == head else "behind HEAD" if head else "unknown"),
           "variation": os.path.isfile(os.path.join(pd, "index", "variation.json"))}
    hub = None
    topo = plane.topology(project)
    for cand in (os.environ.get("CLAUDEHUT_HUB"), topo.get("hub")):
        if cand:
            hub = plane.hub_dir(cand if os.path.isabs(cand) else os.path.join(project, cand))
            break
    hub_info = {"path": hub, "services": 0, "newest_sync": None}
    if hub:
        svcs = plane.read_json(os.path.join(hub, "services.json"), {}) or {}
        hub_info["services"] = len(svcs) if isinstance(svcs, dict) else 0
        syncs = [v.get("synced_at") for v in svcs.values() if isinstance(v, dict) and v.get("synced_at")] \
            if isinstance(svcs, dict) else []
        hub_info["newest_sync"] = max(syncs) if syncs else None
    return {"index": idx, "hub": hub_info}


def collect(project, selftest_results=None, now=None):
    root = packs.plugin_root()
    pj = plane.read_json(os.path.join(root, ".claude-plugin", "plugin.json"), {}) or {}
    manifests, errors, reg = packs.load_all(project)
    pk = [{"pack": r["pack"], "active": r["active"], "version": r.get("version"),
           "registration": reg.get(r["pack"], "unregistered")} for r in packs.evaluate(project, manifests)]
    pk += [{"pack": n, "active": False, "version": None, "registration": st}
           for n, st in sorted(reg.items()) if n not in manifests]
    ts, ttl = tasks(project, now)
    prof = plane.read_json(os.path.join(plane.plane_dir(project), "state", "env-profile.json"), {}) or {}
    out = {"version": {"kernel": pj.get("version"), "root": root, "session": "unknown"},
           "plane": plane.plane_dir(project) if os.path.isdir(plane.plane_dir(project)) else None,
           "packs": pk, "pack_errors": errors, "tasks": ts, "ttl_days": ttl, "knowledge": knowledge(project),
           "host": {"auth_mode": prof.get("auth_mode") or "unknown",
                    "rewriters": prof.get("rewriters") if prof else "unknown", "profile_at": prof.get("at")}}
    out["campaigns"] = []
    try:
        hub = campaign.hub_of(project)
        for c in campaign.campaigns(hub) if hub else []:
            if campaign.repo_entry(c, project):
                out["campaigns"].append(campaign.aggregate(hub, c["id"]))
    except (OSError, ValueError, KeyError):
        pass
    if selftest_results is not None:
        dead = [r["control"] for r in selftest_results if not r["ok"]]
        out["sensors"] = {"controls": len(selftest_results), "alive": len(selftest_results) - len(dead), "dead": dead}
    return out


def render(s):
    lines = [f"version   : kernel {s['version']['kernel']} ({s['version']['root']}); running session: "
             f"{s['version']['session']}"]
    if not s["plane"]:
        lines.append("plane     : none (run claudehut-init)")
    on = [f"{p['pack']} {p['version']}" for p in s["packs"] if p["active"]]
    unreg = [p["pack"] for p in s["packs"] if p["registration"] == "unregistered"]
    stale = [p["pack"] for p in s["packs"] if p["registration"] == "stale"]
    note = []
    if unreg:
        note.append(f"unregistered: {', '.join(unreg)} (no SessionStart register-packs.sh entry in this plane yet)")
    if stale:
        note.append(f"stale: {', '.join(stale)} (registered root or manifest changed — restart the session)")
    lines.append(f"packs     : {', '.join(on) or 'none'}" + (f" — {'; '.join(note)}" if note else ""))
    if s["tasks"]:
        for t in s["tasks"]:
            lines.append(f"task      : {t['id']} phase={t['phase']} route={t['route']} tier={t['tier'] or '-'} "
                         f"review={t['review']} last_event {t['age']}"
                         + (f" STALE (no event for >{s['ttl_days']}d)" if t["stale"] else "")
                         + (f" campaign={t['campaign']}" if t["campaign"] else ""))
    else:
        lines.append("task      : none active")
    k = s["knowledge"]
    ix = k["index"]
    lines.append(f"knowledge : index {('@' + ix['indexed_commit'][:7]) if ix['indexed_commit'] else '-'} ({ix['state']})"
                 f"{'' if ix['variation'] else ', no variation.json'}; hub "
                 + (f"{k['hub']['services']} services, newest sync {k['hub']['newest_sync'] or '-'}" if k["hub"]["path"]
                    else "none"))
    if "sensors" in s:
        se = s["sensors"]
        lines.append(f"sensors   : {se['alive']}/{se['controls']} canaries alive"
                     + (f" — DEAD: {', '.join(se['dead'])}" if se["dead"] else ""))
    else:
        lines.append("sensors   : not checked (claudehut status --selftest runs every canary)")
    for ag in s.get("campaigns") or []:
        lines.append(campaign.render(ag).splitlines()[0])
    h = s["host"]
    lines.append(f"host      : auth {h['auth_mode']}, Bash-rewriting hooks {h['rewriters']}"
                 + (f" (probed {h['profile_at']})" if h["profile_at"] else " (not probed yet)"))
    return "\n".join(lines)
