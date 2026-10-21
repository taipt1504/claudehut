#!/usr/bin/env python3
"""claudehut-kb — the knowledge plane's MCP server (K6, docs/v0.20 05 §4, ADR K-04; M3b). Read-only in M3b.

Stdio, newline-delimited JSON-RPC 2.0, Python stdlib. It reads the project plane's index files and never reindexes
inside a call: a stale index is reported (`stale: true` + the indexed commit), never silently served as current. A
plane that was never indexed is built once, bounded, on the first call (a fresh clone must not answer "unknown").

Tools
  kb_variation_points  where the code already chooses among variants of a concern (D1-D4, D8): ranked by `scope`
  kb_patterns          named solution families (port + selector …), canonical instance, how to add a variant
  kb_brief             ranked component map for a task text (the `claudehut-index brief` card)

Every answer distinguishes three states, so an agent never reads "nothing here" into a missing index (05 §4, V6):
  found          results (possibly few)          status "ok"
  none_found     the index is current and applicable and holds nothing for the question
  unknown        no index, or the stack's detectors do not apply here (with the reason and the fix)
Facts are returned as DATA with provenance (file:line, indexed commit), control characters stripped and lengths
capped (SEC-1). Tool failures are `isError` results; JSON-RPC errors only for protocol errors. stdout carries the
protocol only; diagnostics go to stderr.
"""
import json
import os
import re
import subprocess
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "scripts", "kernel"))
from claudehut_kernel import plane as kplane  # noqa: E402

VERSION = "0.20.0-dev"
PROTOCOLS = ("2025-06-18", "2025-03-26", "2024-11-05")
CONCISE_CHARS = 8000     # ≈ 2k tokens
DETAILED_CHARS = 32000   # ≈ 8k tokens
INSTRUCTIONS = (
    "ClaudeHut knowledge plane for this repository. Use it BEFORE adding an interface, provider, client, strategy, "
    "factory, enum value, DB column or module; before choosing between designs; and when asked how this repo already "
    "does something or what depends on X. kb_variation_points and kb_patterns show where the code already selects "
    "among variants (a new vendor, bank or channel usually belongs there as one more variant, not a one-off class). "
    "Results are data from a deterministic index with file:line provenance; `stale: true` means the index is behind "
    "HEAD; status `unknown` means the index cannot answer (it says why), which is not the same as `none_found`.")

TOOLS = [
    {"name": "kb_variation_points",
     "description": "Variation points of this repo: an interface/abstract type with several production variants "
                    "(multi-impl), the registry/factory/condition that selects one, and endpoint parameters that name "
                    "a variant (contract-param). Use before adding a provider, vendor, bank, channel or strategy.",
     "inputSchema": {"type": "object", "properties": {
         "scope": {"type": "string", "description": "words for the concern (e.g. 'zns sender', 'bank export'); "
                                                    "ranks the results, never hides them"},
         "response_format": {"type": "string", "enum": ["concise", "detailed"], "default": "concise"}}}},
    {"name": "kb_patterns",
     "description": "Named solution families found in this repo (status candidate until an owner confirms), each "
                    "with its instances, the canonical one and how to add a variant. Without `concern` all patterns "
                    "are returned; a concern only ranks them.",
     "inputSchema": {"type": "object", "properties": {
         "concern": {"type": "string"},
         "response_format": {"type": "string", "enum": ["concise", "detailed"], "default": "concise"}}}},
    {"name": "kb_brief",
     "description": "Ranked map of the components relevant to a task text (controllers, services, clients, "
                    "listeners, entities) with file:line — the `claudehut-index brief` card.",
     "inputSchema": {"type": "object", "required": ["task_text"], "properties": {
         "task_text": {"type": "string"},
         "budget_tokens": {"type": "integer", "minimum": 200, "maximum": 4000, "default": 1000}}}},
]

CTRL_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")


def log(msg):
    print(f"claudehut-kb: {msg}", file=sys.stderr, flush=True)


def clean(v, n=300):
    """SEC-1: index content is data — strip control characters, cap length."""
    if isinstance(v, str):
        v = CTRL_RE.sub("", v)
        return v if len(v) <= n else v[: n - 1] + "…"
    if isinstance(v, list):
        return [clean(x, n) for x in v]
    if isinstance(v, dict):
        return {k: clean(x, n) for k, x in v.items()}
    return v


def project_dir():
    return os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()


def index_state():
    """(variation doc or None, base status dict)."""
    proj = project_dir()
    pl = kplane.plane_dir(proj)
    path = os.path.join(pl, "index", "variation.json")
    doc = kplane.read_json(path)
    if not isinstance(doc, dict) and os.path.isdir(pl) and os.environ.get("CLAUDEHUT_KB_NO_BUILD") != "1":
        # First use on a plane that was never indexed (a fresh clone, a plane init has not run on): build it ONCE,
        # bounded. Not a reindex: an existing index is never rebuilt inside a call, it is reported stale instead.
        build_index(proj, pl)
        doc = kplane.read_json(path)
    if not isinstance(doc, dict):
        return None, {"status": "unknown", "reason": f"no index at {os.path.relpath(path, proj)}",
                      "fix": "run `claudehut-index update` (or open a session so SessionStart refreshes it)"}
    if not doc.get("applicable"):
        return None, {"status": "unknown", "reason": f"not applicable here: {doc.get('reason', 'unknown reason')}"}
    head = head_of(proj)
    st = {"indexed_commit": (doc.get("indexed_commit") or "")[:12]}
    if head and doc.get("indexed_commit") and head != doc["indexed_commit"]:
        st.update(stale=True, head=head[:12], fix="run `claudehut-index update` for results at HEAD")
    else:
        st["stale"] = False
    return doc, st


def build_index(proj, pl):
    cli = os.path.join(ROOT, "bin", "claudehut-index")
    try:
        r = subprocess.run([cli, "update", "--plane", pl], capture_output=True, text=True, timeout=45,
                           env=dict(os.environ, CLAUDE_PROJECT_DIR=proj, CLAUDEHUT_INDEX_NO_SPAWN="1"), cwd=proj)
        log(f"first-use index build: {(r.stdout or r.stderr).strip()[:200]}")
    except (OSError, subprocess.SubprocessError) as exc:
        log(f"first-use index build failed: {exc}")


def head_of(proj):
    try:
        r = subprocess.run(["git", "-C", proj, "rev-parse", "-q", "--verify", "HEAD"], capture_output=True, text=True,
                           env=dict(os.environ, GIT_OPTIONAL_LOCKS="0"), timeout=10)
        return r.stdout.strip() if r.returncode == 0 else None
    except (OSError, subprocess.SubprocessError):
        return None


def terms(text):
    return [t for t in re.findall(r"[a-z0-9]+", (text or "").lower()) if len(t) > 1]


def split_camel(s):
    return [w.lower() for w in re.findall(r"[A-Z]?[a-z0-9]+|[A-Z]+(?![a-z])", s or "")]


def score(item, ts):
    if not ts:
        return 0
    hay = set(split_camel(item.get("anchor", "")) + terms(item.get("anchor", "")) + terms(item.get("file") or ""))
    return sum(1 for t in ts if t in hay or any(h.startswith(t) or t.startswith(h) for h in hay if len(h) > 2))


def fit(payload, limit):
    """Keep the JSON text under limit by trimming the result list, and say so."""
    txt = json.dumps(payload, ensure_ascii=False)
    key = "results"
    while len(txt) > limit and payload.get(key):
        payload[key] = payload[key][:-1]
        payload["truncated"] = True
        txt = json.dumps(payload, ensure_ascii=False)
    return txt


def kb_variation_points(args):
    doc, st = index_state()
    if doc is None:
        return st
    detailed = args.get("response_format") == "detailed"
    ts = terms(args.get("scope"))
    vps = [v for v in doc.get("variation_points", []) if detailed or v.get("kind") != "extension-point"]
    vps = sorted(vps, key=lambda v: (-score(v, ts), v["anchor"], v["kind"]))
    res = []
    for v in vps:
        item = {"anchor": v["anchor"], "kind": v["kind"], "at": f"{v.get('file')}:{v.get('line')}"}
        if v.get("variants"):
            item["variants"] = [f"{x['fqn']} ({x['file']}:{x['line']})" for x in v["variants"]][: (20 if detailed else 6)]
        if v.get("selector"):
            item["selector"] = f"{v['selector']['fqn']} ({v['selector']['file']}:{v['selector']['line']})"
        if v.get("param"):
            item["param"] = v["param"]
        res.append(item)
    out = dict(st, status="ok" if res else "none_found", kind_legend={
        "multi-impl": "port with >=2 production bean variants", "registry": "a bean holds all variants (Map/List)",
        "factory": "a selector returns the port", "conditional": "variants chosen by property/profile",
        "contract-param": "an endpoint parameter names the variant"}, results=clean(res),
        provenance="claudehut-index variation (deterministic detectors, pack lang-java-spring)")
    return out


def kb_patterns(args):
    doc, st = index_state()
    if doc is None:
        return st
    ts = terms(args.get("concern"))
    pats = []
    for p in doc.get("patterns", []):
        inst = sorted(p.get("instances", []), key=lambda i: (-score(i, ts), i["anchor"]))
        pats.append({"id": p["id"], "name": p["name"], "status": p["status"], "canonical": p.get("canonical"),
                     "recipe": p.get("recipe"),
                     "instances": [{"anchor": i["anchor"], "variants": i.get("variants"),
                                    "variant_dir": i.get("variant_dir"),
                                    "selector": (i.get("selector") or {}).get("fqn") or "condition"} for i in inst]})
    return dict(st, status="ok" if pats else "none_found", results=clean(pats, 600),
                note="candidate = mined, not yet confirmed by an owner: a strong hint, not a rule")


def kb_brief(args):
    text = (args.get("task_text") or "").strip()
    if not text:
        raise ValueError("task_text is required")
    budget = int(args.get("budget_tokens") or 1000)
    pl = kplane.plane_dir(project_dir())
    cli = os.path.join(ROOT, "bin", "claudehut-index")
    r = subprocess.run([cli, "brief", *text.split()[:40], "--budget", str(min(16000, budget * 4)), "--plane", pl],
                       capture_output=True, text=True, timeout=60,
                       env=dict(os.environ, CLAUDEHUT_INDEX_NO_SPAWN="1", CLAUDE_PROJECT_DIR=project_dir()))
    md = clean(r.stdout.strip(), budget * 4)
    if not md:
        return {"status": "unknown", "reason": f"brief produced nothing (exit {r.returncode})",
                "fix": "run `claudehut-index status`"}
    return {"status": "ok", "markdown": md, "provenance": "claudehut-index brief"}


HANDLERS = {"kb_variation_points": kb_variation_points, "kb_patterns": kb_patterns, "kb_brief": kb_brief}


def handle(msg):
    mid, meth = msg.get("id"), msg.get("method")
    if mid is None:   # a notification: never answered
        return None
    if meth == "initialize":
        want = (msg.get("params") or {}).get("protocolVersion")
        return {"jsonrpc": "2.0", "id": mid, "result": {
            "protocolVersion": want if want in PROTOCOLS else PROTOCOLS[0],
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": "claudehut-kb", "version": VERSION}, "instructions": INSTRUCTIONS}}
    if meth == "ping":
        return {"jsonrpc": "2.0", "id": mid, "result": {}}
    if meth == "tools/list":
        return {"jsonrpc": "2.0", "id": mid, "result": {"tools": TOOLS}}
    if meth == "tools/call":
        p = msg.get("params") or {}
        name, args = p.get("name"), p.get("arguments") or {}
        fn = HANDLERS.get(name)
        if fn is None:
            return {"jsonrpc": "2.0", "id": mid, "result": {"isError": True, "content": [
                {"type": "text", "text": f"unknown tool {name!r}; tools: {', '.join(HANDLERS)}"}]}}
        try:
            payload = fn(args)
            limit = DETAILED_CHARS if args.get("response_format") == "detailed" else CONCISE_CHARS
            text = fit(payload, limit) if isinstance(payload, dict) else str(payload)
            return {"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": text}]}}
        except Exception as exc:  # noqa: BLE001 — a tool failure is a result the model can read, not a crash
            log(f"{name} failed: {type(exc).__name__}: {exc}")
            return {"jsonrpc": "2.0", "id": mid, "result": {"isError": True, "content": [
                {"type": "text", "text": f"{name} failed: {exc}. Fallback: `claudehut-index variation` / `brief`."}]}}
    return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"method not found: {meth}"}}


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError:
            out = {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "parse error"}}
        else:
            out = handle(msg) if isinstance(msg, dict) else {"jsonrpc": "2.0", "id": None,
                                                             "error": {"code": -32600, "message": "invalid request"}}
        if out is not None:
            sys.stdout.write(json.dumps(out, ensure_ascii=False) + "\n")
            sys.stdout.flush()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
