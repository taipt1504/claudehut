"""Task event log (K1, ADR K-03): tasks/<id>/events.jsonl, append-only, one JSON object per line.

The state CLI is the authoritative writer; hooks may only enrich (source="hook"). A single O_APPEND write of a
short line is atomic on POSIX, and the bash CLI already holds the plane lock while it calls the kernel.
"""
import json
import os
import time


def append(task_dir, etype, data=None, source="cli"):
    if not task_dir or not os.path.isdir(task_dir):
        return False
    rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "type": etype, "source": source}
    if data:
        rec["data"] = data
    line = json.dumps(rec, ensure_ascii=False, sort_keys=True) + "\n"
    fd = os.open(os.path.join(task_dir, "events.jsonl"), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        os.write(fd, line.encode("utf-8"))
    finally:
        os.close(fd)
    return True


def read(task_dir):
    path = os.path.join(task_dir, "events.jsonl")
    out = []
    try:
        with open(path, encoding="utf-8") as f:
            for raw in f:
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    out.append(json.loads(raw))
                except ValueError:
                    continue
    except OSError:
        pass
    return out
