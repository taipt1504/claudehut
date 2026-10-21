"""Learning truth maintenance (K6, docs/v0.20/05-knowledge-plane.md §7-§8).

  retract <id> --reason R   status=retracted (+reason, at). Injectors, MEMORY counts and scoring skip it; the row
                            stays for audit. Works on a plane store (L-####) or a hub store (F-####).
  verify  <id> --by X       record verified_by (test name, commit, library source file): required for a fleet copy.

Writes take BOTH locks merge-learnings.sh may use — flock on <store>.lock.flock (where flock exists, e.g. Linux) and
the mkdir lock <store>.lock (stale after 30 s) — and replace the file atomically keeping its mode, so a concurrent
Learn pass never interleaves.
"""
import fcntl
import json
import os
import stat
import time

LOCK_STALE = 30
LOCK_WAIT = 10


class LockError(RuntimeError):
    pass


def _lock(path):
    lock = path + ".lock"
    start = time.time()
    while True:
        try:
            os.mkdir(lock)
            return lock
        except FileExistsError:
            try:
                if time.time() - os.stat(lock).st_mtime >= LOCK_STALE:
                    os.rmdir(lock)
                    continue
            except OSError:
                continue
            if time.time() - start >= LOCK_WAIT:
                raise LockError(f"{lock} held for {LOCK_WAIT}s")
            time.sleep(0.05)


def _load(path):
    rows = []
    with open(path, encoding="utf-8") as f:
        for raw in f:
            raw = raw.strip()
            if raw:
                try:
                    obj = json.loads(raw)
                except ValueError:
                    obj = None
                rows.append(obj if isinstance(obj, dict) else {"_raw": raw})
    return rows


def _save(path, rows):
    tmp = f"{path}.tmp.{os.getpid()}"
    try:
        mode = stat.S_IMODE(os.stat(path).st_mode)
    except OSError:
        mode = 0o644
    with open(tmp, "w", encoding="utf-8") as f:
        for r in rows:
            f.write(r["_raw"] if "_raw" in r else json.dumps(r, ensure_ascii=False, separators=(",", ":")))
            f.write("\n")
    os.chmod(tmp, mode)
    os.replace(tmp, path)


def store_path(project_dir, hub=None):
    from . import plane
    if hub:
        hd = plane.hub_dir(hub) or hub
        return os.path.join(hd, "fleet-learnings.jsonl")
    return os.path.join(plane.plane_dir(project_dir), "learnings.jsonl")


def update(path, entry_id, fields):
    """Set fields on the entry with this id. Returns the updated entry, or None when the id is absent."""
    if not os.path.isfile(path):
        return None
    ffd = os.open(path + ".lock.flock", os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(ffd, fcntl.LOCK_EX)
    except OSError:
        pass
    try:
        lock = _lock(path)
    except LockError:
        os.close(ffd)
        raise
    try:
        rows = _load(path)
        hit = None
        for r in rows:
            if r.get("id") == entry_id:
                r.update(fields)
                hit = r
        if hit is not None:
            _save(path, rows)
        return hit
    finally:
        try:
            os.rmdir(lock)
        except OSError:
            pass
        try:
            fcntl.flock(ffd, fcntl.LOCK_UN)
        finally:
            os.close(ffd)


def now():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
