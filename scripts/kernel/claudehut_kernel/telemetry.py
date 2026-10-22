"""K9 telemetry bridge (docs/v0.20 08 §1; M5e): a task's event log → OpenTelemetry GenAI-shaped spans, written to a
local file. Nothing is sent anywhere: a collector, if the user runs one, reads the file (OTEL_* does not reach hooks,
so an exporter has to be configured explicitly anyway).

The GenAI semantic conventions are still Development, so the whole mapping lives in MAPPING below and nowhere else.
One task = one `invoke_workflow` span; a gate outcome = an `execute_tool` child span (the gate is the tool); every
other event is a span event on the task span.
"""
import calendar
import hashlib
import json
import os
import time

from . import events, plane

MAPPING = {
    "task": {"name": "invoke_workflow {route}", "attrs": {"gen_ai.operation.name": "invoke_workflow",
                                                          "gen_ai.system": "claude_code"}},
    "gate": {"prefix": "gate.", "name": "execute_tool gate.{gate}",
             "attrs": {"gen_ai.operation.name": "execute_tool", "gen_ai.tool.type": "extension"}},
    "task_attrs": {"id": "claudehut.task.id", "route": "claudehut.task.route", "tier": "claudehut.task.tier",
                   "profile": "claudehut.task.profile", "status": "claudehut.task.status",
                   "campaign_id": "claudehut.campaign.id"},
}


def _ns(ts):
    try:
        return calendar.timegm(time.strptime(ts, "%Y-%m-%dT%H:%M:%SZ")) * 10**9
    except (TypeError, ValueError):
        return None


def _id(*parts, n=16):
    return hashlib.sha256("\0".join(map(str, parts)).encode()).hexdigest()[:n]


def spans(task_dir):
    task = plane.load_task(task_dir)
    evs = events.read(task_dir)
    tid = task.get("id") or os.path.basename(task_dir)
    trace = _id("trace", tid, n=32)
    root = _id("task", tid)
    times = [_ns(e.get("ts")) for e in evs if _ns(e.get("ts"))]
    start, end = (min(times), max(times)) if times else (None, None)
    m = MAPPING
    attrs = dict(m["task"]["attrs"])
    attrs.update({v: task.get(k) for k, v in m["task_attrs"].items() if task.get(k) is not None})
    out = [{"traceId": trace, "spanId": root, "name": m["task"]["name"].format(route=task.get("route") or "?"),
            "startTimeUnixNano": start, "endTimeUnixNano": end, "attributes": attrs, "events": []}]
    for i, e in enumerate(evs):
        t = e.get("type") or ""
        if t.startswith(m["gate"]["prefix"]):
            d = e.get("data") or {}
            a = dict(m["gate"]["attrs"])
            a.update({"gen_ai.tool.name": f"gate.{d.get('gate')}", "claudehut.gate.outcome": t[len("gate."):],
                      "claudehut.gate.mode": d.get("mode"),
                      "claudehut.gate.invariants": sorted({v.get("invariant") for v in d.get("violations") or []
                                                           if v.get("invariant")})})
            out.append({"traceId": trace, "spanId": _id("gate", tid, i), "parentSpanId": root,
                        "name": m["gate"]["name"].format(gate=d.get("gate")), "startTimeUnixNano": _ns(e.get("ts")),
                        "endTimeUnixNano": _ns(e.get("ts")), "attributes": a, "events": []})
        else:
            out[0]["events"].append({"name": t, "timeUnixNano": _ns(e.get("ts")),
                                     "attributes": {"claudehut.event.rev": e.get("rev"),
                                                    "claudehut.event.source": e.get("source")}})
    return out


def export(task_dirs, path):
    """Write {resourceSpans: […]} to `path` — OTLP's envelope, with attributes as a plain map (not OTLP's typed
    key/value list): a converter or collector config maps it; → number of spans."""
    allspans = [s for td in task_dirs for s in spans(td)]
    doc = {"resourceSpans": [{"resource": {"attributes": {"service.name": "claudehut"}},
                              "scopeSpans": [{"scope": {"name": "claudehut-kernel"}, "spans": allspans}]}]}
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False)
    return len(allspans)
