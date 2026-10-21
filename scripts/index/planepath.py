"""Plane location for the index tools (ADR K-18). The rule itself lives in scripts/kernel/claudehut_kernel/plane.py
(bash twin: scripts/lib/plane-path.sh); this module only re-exports it and adds the inverse (plane -> repo)."""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "kernel"))
from claudehut_kernel.plane import PLANE_LEGACY, PLANE_NEW, plane_dir  # noqa: E402,F401


def repo_of(plane):
    """<repo>/.claudehut -> <repo>; <repo>/.claude/claudehut -> <repo>."""
    p = os.path.normpath(plane)
    if os.path.basename(p) == PLANE_NEW:
        return os.path.dirname(p)
    return os.path.dirname(os.path.dirname(p))


def hub_dirs(root):
    """Candidate hub data dirs under a hub root, new layout first."""
    return [os.path.join(root, PLANE_NEW, "hub"), os.path.join(root, PLANE_LEGACY, "hub")]
