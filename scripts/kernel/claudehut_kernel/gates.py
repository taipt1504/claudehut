"""Invariant engine (K2, ADR K-05). Invariants are checked ONLY at explicit task transitions.

Mode: CLAUDEHUT_GATE_MODE env > topology.json .gates.mode > "warn". In "warn" a violation is recorded and
reported but the transition proceeds; in "block" it is refused unless the caller passes an override reason.
Every outcome is an event in the task log so metrics can count warn/block/override (08 §3).
"""
import os

from . import events, plane

MODES = ("warn", "block")


def mode(project_dir):
    m = (os.environ.get("CLAUDEHUT_GATE_MODE") or "").strip().lower()
    if m in MODES:
        return m
    g = (plane.topology(project_dir).get("gates") or {})
    m = str(g.get("mode") or "").strip().lower() if isinstance(g, dict) else ""
    return m if m in MODES else "warn"


def decide(project_dir, task_dir, gate, violations, override=None):
    """Return a decision dict and record the matching event. decision ∈ pass|warn|override|block."""
    m = mode(project_dir)
    if not violations:
        decision = "pass"
    elif m == "warn":
        decision = "warn"
    elif override and override.strip():
        decision = "override"
    else:
        decision = "block"
    if violations:
        etype = {"warn": "gate.warned", "override": "gate.overridden", "block": "gate.blocked"}[decision]
        data = {"gate": gate, "mode": m, "violations": violations}
        if decision == "override":
            data["reason"] = override.strip()
        events.append(task_dir, etype, data)
    return {"gate": gate, "mode": m, "decision": decision, "violations": violations}
