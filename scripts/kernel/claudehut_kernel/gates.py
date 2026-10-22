"""Invariant engine (K2, ADR K-05). Invariants are checked ONLY at explicit task transitions.

Mode: CLAUDEHUT_GATE_MODE env > topology.json .gates.mode > "warn". In "warn" a violation is recorded and
reported but the transition proceeds; in "block" it is refused unless the caller passes an override reason.
Every outcome is an event in the task log so metrics can count warn/block/override (08 §3).

Pack invariants (04 §2, Q6) are declared in an active pack's manifest `invariants` and checked here; their mode is
topology.json .gates.pack_mode > the manifest entry's "mode" > "warn". The kernel switch (env, .gates.mode) never
escalates them: a pack invariant blocks only when the project asks for that explicitly.
"""
import os
import sys

from . import events, packs, plane, verify

MODES = ("warn", "block")


def mode(project_dir):
    m = (os.environ.get("CLAUDEHUT_GATE_MODE") or "").strip().lower()
    if m in MODES:
        return m
    g = (plane.topology(project_dir).get("gates") or {})
    m = str(g.get("mode") or "").strip().lower() if isinstance(g, dict) else ""
    return m if m in MODES else "warn"


def pack_mode(project_dir, declared):
    g = (plane.topology(project_dir).get("gates") or {})
    m = str(g.get("pack_mode") or "").strip().lower() if isinstance(g, dict) else ""
    return m if m in MODES else (declared if declared in MODES else "warn")


def pack_invariants(project_dir, at):
    """[(pack, entry)] declared for transition `at` by the packs active on this project."""
    manifests, _ = packs.load()
    active = {r["pack"] for r in packs.evaluate(project_dir, manifests) if r["active"]}
    return [(n, e) for n in sorted(active) for e in manifests[n].get("invariants") or []
            if isinstance(e, dict) and e.get("at") == at]


def tier_needs_decision(task, task_dir):
    """plan.tier-needs-decision (deliberation pack, a2 §1): tier T2/T3 needs the decision record before the plan."""
    tier = task.get("tier") or ""
    if tier in ("T2", "T3") and not os.path.isfile(os.path.join(task_dir, "decision.md")):
        return [{"kind": "decision-missing", "at": f"tier {tier}",
                 "fix": f"a {tier} task records its design decision before the plan: run the claudehut:deliberate "
                        f"skill, which writes <plane>/tasks/{os.path.basename(task_dir)}/decision.md."}]
    return []


PACK_CHECKS = {"plan.tier-needs-decision": tier_needs_decision}


def decide(project_dir, task_dir, gate, violations, override=None, m=None):
    """Return a decision dict and record the matching event. decision ∈ pass|warn|override|block."""
    m = m or mode(project_dir)
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


def _human(problems, prefix):
    for p in problems:
        where = p.get("at") or ""
        what = p.get("path") or p.get("row") or ", ".join(map(str, p.get("items") or p.get("repos") or []))
        print(f"{prefix}: {p['kind']}{(' ' + where) if where else ''}{(' — ' + what) if what else ''}. {p.get('fix', '')}",
              file=sys.stderr)


def run(which, project, task_dir, evidence=None, status="done", override=None, ts=None, record=True):
    """One gate at one transition → (rc, out). rc 0 proceed (pass|warn|override), 1 refused (block), 2 unknown gate.
    Human lines go to stderr; `out` carries the decision and, for review-pass, the binding to store.
    record=False (the Python state writer): the transition's own state event carries the outcome, so the gate writes
    only its gate.* events, not the informational review.verdict / task.ended lines the bash writer relies on."""
    if os.environ.get("CLAUDEHUT_KERNEL_FAULT") == "gate":   # test-only canary: the gate-crash path (verify-tests R7-py)
        raise RuntimeError("injected gate fault (CLAUDEHUT_KERNEL_FAULT=gate)")
    task = plane.load_task(task_dir)
    out = {}
    if which == "review-pass":
        ev = plane.abspath(project, evidence)
        _, claim_problems = verify.check_claims(ev, project, plane.repo_dirs(project, task), task.get("base") or {})
        violations = [dict(p, invariant="review.claims-resolve") for p in claim_problems]
        violations += [dict(p, invariant="review.no-open-findings") for p in verify.check_findings(task, ev)]
        d = decide(project, task_dir, "review-pass", violations, override)
        if d["decision"] != "block":
            out["binding"] = verify.binding(project, task, ts)
            if record:
                events.append(task_dir, "review.verdict", {"verdict": "pass", "evidence": evidence, "gate": d["decision"]})
    elif which == "end":
        violations = []
        if status == "done":
            review = task.get("review") or "pending"
            if review not in ("pass", "capped"):
                violations.append({"kind": "review-not-done", "invariant": "end.done-requires-review",
                                   "fix": f"review is '{review}': run the review and `claudehut-state set-review pass "
                                          f"--evidence …`, or end with --status abandoned, or pass --override \"<reason>\"."})
            elif review == "pass":
                violations += [dict(p, invariant="end.verdict-current") for p in verify.check_verdict(project, task)]
        d = decide(project, task_dir, "end", violations, override)
        if d["decision"] != "block" and record:
            events.append(task_dir, "task.ended", {"status": status, "gate": d["decision"]})
    elif which == "plan":
        violations, declared = [], "warn"
        if (task.get("tier") or "") in ("T2", "T3"):   # the only pack check at set-plan; skip pack detection otherwise
            for pack, e in pack_invariants(project, "set-plan"):
                check = PACK_CHECKS.get(e.get("id"))
                if check:
                    violations += [dict(p, invariant=e["id"], pack=pack) for p in check(task, task_dir)]
                    declared = e.get("mode") or declared
        d = decide(project, task_dir, "plan", violations, override, m=pack_mode(project, declared))
    else:
        print(f"unknown gate {which}", file=sys.stderr)
        return 2, {}
    out.update(d)
    if d["violations"]:
        label = {"warn": "WARN (recorded; the transition proceeds, no --override needed)", "override": "OVERRIDDEN (recorded)",
                 "block": "BLOCKED"}[d["decision"]]
        _human(d["violations"], f"gate {which} {label}")
    return (1 if d["decision"] == "block" else 0), out
