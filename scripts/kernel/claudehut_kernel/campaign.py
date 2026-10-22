"""K8 campaigns (docs/v0.20 04 §6, 09 §6, ADR K-09; M5c): one change across many repos, managed as one object.

Layout in the hub (<HUB>/.claudehut/hub or the legacy hub dir, see plane.hub_dir):
  campaigns/<id>/campaign.json             {schema, id, goal, owner, template {path, rev}, repos [{repo, path?,
                                            order, owner?, addendum?}], questions [], created, updated, history []}
  campaigns/<id>/repos/<repo>/events.jsonl  the child task's events, mirrored (append-only, deduplicated)
  campaigns/<id>/repos/<repo>/state.json    the child task's latest projection summary
  campaigns/<id>/repos/<repo>/lease.json    soft lock: one writer session per repo, with an expiry (P10)

Rules kept from the kernel design:
- The state CLI is the only task writer (K1). SessionStart only SAYS that a campaign has work for this repo (pull,
  04 §6); `claudehut-state start --campaign <id>` creates the child task. 09 §6 step 2 ("SessionStart creates the
  child task") is deliberately not followed: a hook does not write task state.
- The template is referenced, never copied (MAO-2): a child task records `template_rev`; when the campaign's rev
  moves on, active children are reported `drifted` until they are re-anchored.
- A campaign carries no authority (Q10): approval stays with the repo owner's session; `waiting-approval` is
  only a state the aggregate reports.
- Mirroring is idempotent: an event already in the hub (same task, same canonical JSON) is never appended twice,
  so a retry after a crash or a re-run changes nothing (04 §1 side effects idempotent by task + step).
"""
import hashlib
import json
import os
import time

from . import plane

LEASE_S = 4 * 3600
STATUS_ORDER = ("blocked", "waiting-approval", "in-progress", "not-started", "done", "abandoned")


def _now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _write(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=1)
        f.write("\n")
    os.replace(tmp, path)


def _sha_file(path):
    with open(path, "rb") as f:
        return "sha256:" + hashlib.sha256(f.read()).hexdigest()


def hub_of(project, explicit=None):
    topo = plane.topology(project) if project else {}
    for cand in (explicit, os.environ.get("CLAUDEHUT_HUB"), topo.get("hub")):
        if cand:
            return plane.hub_dir(cand if os.path.isabs(cand) or not project else os.path.join(project, cand))
    return None


def _cdir(hub, cid):
    if not cid or "/" in cid or cid.startswith("."):
        raise ValueError(f"bad campaign id {cid!r}")
    return os.path.join(hub, "campaigns", cid)


def hub_root(hub):
    """The directory a hub dir belongs to (template paths are relative to it)."""
    h = hub.rstrip("/")
    for rel in (plane.PLANE_NEW, plane.PLANE_LEGACY):
        if h.endswith("/" + rel + "/hub"):
            return h[: -len("/" + rel + "/hub")]
    return h


def load(hub, cid):
    c = plane.read_json(os.path.join(_cdir(hub, cid), "campaign.json"))
    if not isinstance(c, dict):
        raise ValueError(f"no campaign {cid} in {hub}")
    return c


def create(hub, cid, goal, template, repos, owner, ts=None):
    """repos: [(name, path|None)] in rollout order. The template is a file under the hub root."""
    d = _cdir(hub, cid)
    if os.path.exists(os.path.join(d, "campaign.json")):
        raise ValueError(f"campaign {cid} exists")
    tp = os.path.join(hub_root(hub), template)
    if not os.path.isfile(tp):
        raise ValueError(f"template not found: {template} (relative to the hub root {hub_root(hub)})")
    ts = ts or _now()
    c = {"schema": 1, "id": cid, "goal": goal, "owner": owner,
         "template": {"path": template, "rev": _sha_file(tp)},
         "repos": [dict({"repo": n, "order": i + 1}, **({"path": p} if p else {})) for i, (n, p) in enumerate(repos)],
         "questions": [], "created": ts, "updated": ts, "history": []}
    _write(os.path.join(d, "campaign.json"), c)
    return c


def update_template(hub, cid, ts=None):
    """Re-hash the referenced template; a changed rev is recorded (history) and drifts the active children."""
    c = load(hub, cid)
    rev = _sha_file(os.path.join(hub_root(hub), c["template"]["path"]))
    if rev == c["template"]["rev"]:
        return c, False
    c["history"].append({"at": ts or _now(), "template_rev": c["template"]["rev"]})
    c["template"]["rev"] = rev
    c["updated"] = ts or _now()
    _write(os.path.join(_cdir(hub, cid), "campaign.json"), c)
    return c, True


def repo_entry(c, project):
    """The campaign's entry for this project: by path (resolved) first, else by the repo dir's name."""
    real = os.path.realpath(project)
    for r in c.get("repos") or []:
        if r.get("path") and os.path.realpath(r["path"]) == real:
            return r
    name = os.path.basename(real)
    return next((r for r in c.get("repos") or [] if r.get("repo") == name and not r.get("path")), None)


def campaigns(hub):
    d = os.path.join(hub, "campaigns")
    out = []
    for cid in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        try:
            out.append(load(hub, cid))
        except ValueError:
            continue
    return out


# ── lease ───────────────────────────────────────────────────────────────────────────────────────────────────────
def acquire(hub, cid, repo, session, branch="", now=None, ttl=LEASE_S, force=False):
    """→ (ok, holder). Exclusive create; an expired lease, one this session already holds, or `force` (a recorded
    user decision) replaces it. Accepted race (a soft lock, P10): two sessions taking over the SAME expired lease at
    the same instant can both succeed; a live lease is never taken without `force`."""
    now = now or time.time()
    p = os.path.join(_cdir(hub, cid), "repos", repo, "lease.json")
    os.makedirs(os.path.dirname(p), exist_ok=True)
    lease = {"session": session, "branch": branch, "expires": now + ttl,
             "expires_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now + ttl))}
    for _ in range(2):
        try:
            fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                json.dump(lease, f)
            return True, lease
        except FileExistsError:
            cur = plane.read_json(p, {}) or {}
            if force or cur.get("session") == session or float(cur.get("expires") or 0) < now:
                try:
                    os.remove(p)
                except FileNotFoundError:
                    pass
                continue
            return False, cur
    return False, plane.read_json(p, {}) or {}


def holder(hub, cid, repo):
    return plane.read_json(os.path.join(_cdir(hub, cid), "repos", repo, "lease.json"))


def release(hub, cid, repo, session):
    p = os.path.join(_cdir(hub, cid), "repos", repo, "lease.json")
    cur = plane.read_json(p, {}) or {}
    if cur.get("session") == session:
        try:
            os.remove(p)
        except FileNotFoundError:
            pass


# ── mirror + aggregate ──────────────────────────────────────────────────────────────────────────────────────────
def _canon(e):
    return json.dumps(e, sort_keys=True, ensure_ascii=False, separators=(",", ":"))


def mirror(hub, cid, repo, task_dir):
    """Append the task's events not yet in the hub, then rewrite the summary. → number of events appended."""
    d = os.path.join(_cdir(hub, cid), "repos", repo)
    os.makedirs(d, exist_ok=True)
    task = plane.load_task(task_dir)
    tid = task.get("id") or os.path.basename(task_dir)
    hp = os.path.join(d, "events.jsonl")
    seen = set()
    if os.path.isfile(hp):
        with open(hp, encoding="utf-8") as f:
            for line in f:
                try:
                    o = json.loads(line)
                    seen.add((o.get("task"), _canon(o.get("e"))))
                except ValueError:
                    continue
    new = []
    ep = os.path.join(task_dir, "events.jsonl")
    if os.path.isfile(ep):
        with open(ep, encoding="utf-8") as f:
            for line in f:
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                k = (tid, _canon(e))
                if k not in seen:
                    seen.add(k)
                    new.append(json.dumps({"task": tid, "e": e}, ensure_ascii=False))
    if new:
        with open(hp, "a", encoding="utf-8") as f:
            f.write("\n".join(new) + "\n")
    summary = {"task": tid, "status": task.get("status"), "phase": task.get("phase"), "review": task.get("review"),
               "template_rev": task.get("campaign_template_rev"), "updated": task.get("updated"),
               "blocked": _blocked(ep)}
    sp = os.path.join(d, "state.json")
    if plane.read_json(sp) != summary:
        _write(sp, summary)
    return len(new)


def _blocked(events_path):
    """True when the newest outcome is a refusal (gate.blocked) or an open escalation, with no successful
    transition (a state event, which carries `rev`) or passed gate after it."""
    blocked = False
    if os.path.isfile(events_path):
        with open(events_path, encoding="utf-8") as f:
            for line in f:
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                t = e.get("type", "")
                if t in ("gate.blocked", "escalation.raised"):
                    blocked = True
                elif "rev" in e or t in ("gate.warned", "gate.overridden"):
                    blocked = False
    return blocked


def repo_status(summary):
    if not summary:
        return "not-started"
    st = summary.get("status")
    if st in ("done", "abandoned"):
        return st
    if st == "superseded":   # the child was closed by another task in its session: the repo needs a task again
        return "not-started"
    if summary.get("blocked"):
        return "blocked"
    if summary.get("review") in ("pass", "capped"):
        return "waiting-approval"   # reviewed; the repo owner approves in that repo's session (Q10)
    return "in-progress"


def aggregate(hub, cid):
    c = load(hub, cid)
    rows = []
    for r in sorted(c.get("repos") or [], key=lambda x: x.get("order", 0)):
        d = os.path.join(_cdir(hub, cid), "repos", r["repo"])
        s = plane.read_json(os.path.join(d, "state.json"))
        st = repo_status(s)
        lease = plane.read_json(os.path.join(d, "lease.json"))
        rows.append({"repo": r["repo"], "order": r.get("order"), "status": st, "task": (s or {}).get("task"),
                     "drifted": bool(s) and st not in ("done", "abandoned")
                     and (s.get("template_rev") or "") != c["template"]["rev"],
                     "lease": (lease or {}).get("session")})
    counts = {k: sum(1 for x in rows if x["status"] == k) for k in STATUS_ORDER}
    return {"id": cid, "goal": c.get("goal"), "template": c["template"], "repos": rows, "counts": counts,
            "total": len(rows)}


def render(a):
    n = a["total"]
    head = f"campaign  : {a['id']} {a['counts']['done']}/{n} done"
    extra = [f"{a['counts'][k]} {k}" for k in STATUS_ORDER if k != "done" and a["counts"][k]]
    lines = [head + (", " + ", ".join(extra) if extra else "")
             + f" (template {a['template']['path']}@{a['template']['rev'][7:14]})"]
    for r in a["repos"]:
        lines.append(f"  {r['order']}. {r['repo']:<20} {r['status']}" + (f" task {r['task']}" if r["task"] else "")
                     + (" DRIFTED (template changed since the task started)" if r["drifted"] else "")
                     + (f" lease {r['lease']}" if r["lease"] else ""))
    return "\n".join(lines)


def pending_line(project):
    """One fixed-shape line for the per-session SessionStart context, or ''. Names campaigns that target this repo
    and whose child here is not finished; says how to start or that a task exists."""
    hub = hub_of(project)
    if not hub:
        return ""
    parts = []
    for c in campaigns(hub):
        r = repo_entry(c, project)
        if not r:
            continue
        s = plane.read_json(os.path.join(_cdir(hub, c["id"]), "repos", r["repo"], "state.json"))
        st = repo_status(s)
        if st in ("done", "abandoned"):
            continue
        if st == "not-started":
            parts.append(f"{c['id']} (start: claudehut-state start --campaign {c['id']} --route light|full --slug <s>)")
        else:
            parts.append(f"{c['id']} (task {s.get('task')}: {st})")
    if not parts:
        return ""
    return ("Campaign work for this repo (data from the hub; it carries no approval): " + "; ".join(parts[:3])
            + ". Details: claudehut status --campaign <id>.")
