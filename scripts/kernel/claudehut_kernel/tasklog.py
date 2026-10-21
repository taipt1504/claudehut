"""Task event log as the source of truth (K1, docs/v0.20 04 §1, ADR K-03): tasks/<id>/events.jsonl → task.json.

A STATE event carries an integer `rev` and, under `data`, either a `snapshot` (the whole record: task.started,
task.imported) or a `patch` (+ optional `unset` list). Only state events change the projection; every other event in
the same log (gate.*, budget.exceeded, and the review.verdict/task.ended lines the 0.12.7 gate CLI wrote) is
information and is skipped, so replaying an old log never diverges.

task.json stays the file hooks read: the writer appends the event FIRST, then writes the projection with
`event_rev` = the rev it reflects. A crash between the two leaves the log ahead (rev > event_rev): the next writer
re-projects before acting. A task.json changed by anyone else (the bash fallback writer, a hand edit) no longer
equals the projection: the next writer records it as a task.imported snapshot, so the log stays the truth.
"""
import copy

from . import events

REV_KEY = "event_rev"


def is_state_event(e):
    d = e.get("data") if isinstance(e, dict) else None
    return isinstance(d, dict) and isinstance(e.get("rev"), int) and ("snapshot" in d or "patch" in d or "unset" in d)


def strip(task):
    if task is None:
        return None
    t = dict(task)
    t.pop(REV_KEY, None)
    return t


def project(evs):
    """Fold the state events → (task or None, last rev). The task carries event_rev as its last key."""
    task, rev = None, 0
    for e in evs:
        if not is_state_event(e):
            continue
        d = e["data"]
        if "snapshot" in d:
            task = copy.deepcopy(d["snapshot"]) if isinstance(d["snapshot"], dict) else None
        elif task is not None:
            for k, v in (d.get("patch") or {}).items():
                task[k] = copy.deepcopy(v)
            for k in d.get("unset") or []:
                task.pop(k, None)
        else:
            continue
        rev = e["rev"]
    if task is not None:
        task.pop(REV_KEY, None)
        task[REV_KEY] = rev
    return task, rev


def diff(old, new):
    """(patch, unset) turning old into new, event_rev excluded."""
    patch = {k: v for k, v in new.items() if k != REV_KEY and (k not in old or old[k] != v or type(old[k]) is not type(v))}
    unset = [k for k in old if k != REV_KEY and k not in new]
    return patch, unset


def commit(task_dir, old, new, etype, data=None, session=None):
    """Append the state event for old → new (a snapshot when old is None), importing first when the recorded
    projection no longer matches `old`. Returns `new` with event_rev set (last key); the caller writes it."""
    proj, rev = project(events.read(task_dir))
    extra = {"session": session} if session else {}
    if old is not None and strip(proj) != strip(old):
        rev += 1
        events.append(task_dir, "task.imported", {"snapshot": strip(old)}, extra=dict(extra, rev=rev))
    payload = dict(data or {})
    if old is None:
        payload["snapshot"] = strip(new)
    else:
        patch, unset = diff(strip(old), strip(new))
        payload["patch"] = patch
        if unset:
            payload["unset"] = unset
    rev += 1
    if not events.append(task_dir, etype, payload, extra=dict(extra, rev=rev)):
        raise OSError(f"cannot append to {task_dir}/events.jsonl")
    out = strip(new)
    out[REV_KEY] = rev
    return out


def ahead(task_dir, task):
    """The projection when the log is ahead of task.json (a crash after the append), else None."""
    proj, rev = project(events.read(task_dir))
    if proj is not None and rev > (task.get(REV_KEY) if isinstance(task.get(REV_KEY), int) else 0):
        return proj
    return None
