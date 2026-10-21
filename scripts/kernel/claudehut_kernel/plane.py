"""Plane and task lookup. Read-only helpers; the bash state CLI stays the writer of task.json."""
import json
import os


def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


PLANE_NEW = ".claudehut"
PLANE_LEGACY = os.path.join(".claude", "claudehut")


def plane_dir(project_dir):
    """ADR K-18: <repo>/.claudehut (new) wins, else <repo>/.claude/claudehut (legacy), else the new location.
    Same rule as scripts/lib/plane-path.sh — keep them identical."""
    for rel in (PLANE_NEW, PLANE_LEGACY):
        d = os.path.join(project_dir, rel)
        if os.path.isdir(d):
            return d
    return os.path.join(project_dir, PLANE_NEW)


def hub_dir(root):
    """The hub data dir of a hub root (or of the hub dir itself), new layout first; None when there is none."""
    root = root.rstrip("/")
    for rel in (PLANE_NEW, PLANE_LEGACY):
        if root.endswith("/" + rel + "/hub"):
            root = root[: -len("/" + rel + "/hub")]
    for rel in (PLANE_NEW, PLANE_LEGACY):
        d = os.path.join(root, rel, "hub")
        if os.path.isdir(d):
            return d
    return root if os.path.isfile(os.path.join(root, "hub.json")) else None


def is_plane_path(rel):
    rel = rel.replace(os.sep, "/")
    return any(rel.startswith(x + "/") or ("/" + x + "/") in rel for x in (PLANE_NEW, ".claude/claudehut"))


def topology(project_dir):
    return read_json(os.path.join(plane_dir(project_dir), "topology.json"), {}) or {}


def load_task(task_dir):
    return read_json(os.path.join(task_dir, "task.json"), {}) or {}


def repo_dirs(project_dir, task):
    """Repo roots of a task, from task.base keys ('.' = the project). Falls back to the project itself."""
    out = []
    for key in (task.get("base") or {"." : None}):
        path = project_dir if key == "." else (key if os.path.isabs(key) else os.path.join(project_dir, key))
        if os.path.isdir(path):
            out.append((key, path))
    return out or [(".", project_dir)]


def abspath(project_dir, p):
    if not p:
        return None
    return p if os.path.isabs(p) else os.path.join(project_dir, p)
