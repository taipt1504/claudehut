"""Plane and task lookup. Read-only helpers; the bash state CLI stays the writer of task.json."""
import json
import os


def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def plane_dir(project_dir):
    return os.path.join(project_dir, ".claude", "claudehut")


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
