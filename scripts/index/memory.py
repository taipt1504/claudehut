#!/usr/bin/env python3
"""Regenerate the machine-written part of MEMORY.md (07 §8.1, ADR-IDX-6). Stdlib only.

MEMORY.md is @import-ed whole, so every byte is paid on every turn. This script owns the block between
<!-- claudehut:generated:start --> and <!-- claudehut:generated:end --> (<= 2048 B): pointers to the plane,
topology, the index CLI and the top learnings topics -- never learning bodies. Everything outside the
markers is hand-written and is kept byte for byte, except the v0.11 learner's per-task blocks (see below).

A legacy file (no markers, v0.11 template + learner-appended blocks) is migrated once: sections whose
heading is a template or learner form are MOVED to MEMORY-history.md (appended, never deleted), every other
section stays verbatim, and the generated block is inserted. A file with markers only moves the learner's
per-task blocks (`## Reuse additions (`, `## Topics (`) found outside the block. Re-running is a no-op.

Usage: memory.py [--plane DIR] [--plugin-root DIR] [--no-migrate] [--check] [--json]
  --plane DIR     the .claude/claudehut directory (default: $CLAUDE_PROJECT_DIR/.claude/claudehut, else ./)
  --no-migrate    only refresh a file that already has markers (merge-learnings uses this)
  --check         report what would change, write nothing
  --json          print the report as one JSON object
Exit 0 always; one report line on stdout.
"""
import json
import os
import re
import sys
import tempfile
import time

START = "<!-- claudehut:generated:start -->"
END = "<!-- claudehut:generated:end -->"
BLOCK_MAX = 2048
FILE_BUDGET = 8192
TOPICS_MAX = 8

# Headings the v0.11 template and the learner wrote. Only these move; anything else is hand-written.
MACHINE_H1 = re.compile(r"^# ClaudeHut memory index\b")
MACHINE_H2 = re.compile(r"^## (Always loaded|On demand|Path-scoped rules|Dispatch convention|Topics|Reuse additions)\b")
# The v0.11 learner's per-task blocks ("## Reuse additions (task-0001, …)", "## Topics (task-0001)"). A file that
# already has markers can still carry them below the end marker; only this narrow form moves from there.
PER_TASK_H2 = re.compile(r"^## (Reuse additions|Topics) \(")

STOP = set("""the and for with into from this that when then than are was were use using used via not all any
its it's but can you your our has have had does did per each also only must should would could will
over under after before about into onto off out new get set run add fix one two""".split())


def args_parse(argv):
    a = {"plane": None, "plugin_root": None, "migrate": True, "check": False, "json": False}
    i = 0
    while i < len(argv):
        k = argv[i]
        if k == "--plane" and i + 1 < len(argv):
            a["plane"] = argv[i + 1]; i += 2; continue
        if k == "--plugin-root" and i + 1 < len(argv):
            a["plugin_root"] = argv[i + 1]; i += 2; continue
        if k == "--no-migrate":
            a["migrate"] = False
        elif k == "--check":
            a["check"] = True
        elif k == "--json":
            a["json"] = True
        i += 1
    return a


def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return None


def resolve_language(plane, topo):
    """ADR-R7 order: plane topology.json.language -> hub hub.json.language (microservice, M6) -> en."""
    lang = (topo or {}).get("language")
    if lang in ("vi", "en"):
        return lang
    hub = os.environ.get("CLAUDEHUT_HUB") or (topo or {}).get("hub")
    if hub:
        base = hub if os.path.isabs(hub) else os.path.normpath(os.path.join(os.path.dirname(os.path.dirname(plane)), hub))
        for cand in (os.path.join(base, ".claude", "claudehut", "hub", "hub.json"), os.path.join(base, "hub.json")):
            h = read_json(cand)
            if isinstance(h, dict) and h.get("language") in ("vi", "en"):
                return h["language"]
    return "en"


def trigger_tokens(t):
    return [x for x in re.findall(r"[a-z0-9+_]+", (t or "").lower()) if x not in STOP and x != "ms" and len(x) > 1]


def load_learnings(path):
    out = []
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    e = json.loads(line)
                except Exception:
                    continue
                if isinstance(e, dict):
                    out.append(e)
    except OSError:
        pass
    return out


def topics(entries):
    """Top (category, trigger-token) pairs by number of live entries: a pointer an agent can jq for."""
    counts = {}
    for e in entries:
        if e.get("status") == "superseded":
            continue
        if not str(e.get("learning") or e.get("text") or "").strip():
            continue
        cat = str(e.get("category") or "note")
        for tok in set(trigger_tokens(e.get("trigger"))):
            counts[(cat, tok)] = counts.get((cat, tok), 0) + 1
    ranked = sorted(counts.items(), key=lambda kv: (-kv[1], kv[0][0], kv[0][1]))
    picked, used = [], set()
    for (cat, tok), n in ranked:
        if tok in used:
            continue
        used.add(tok)
        picked.append((cat, tok, n))
        if len(picked) >= TOPICS_MAX:
            break
    return picked


def live_count(entries):
    return sum(1 for e in entries if e.get("status") != "superseded" and str(e.get("learning") or e.get("text") or "").strip())


def build_block(plane, plugin_root, name):
    topo = read_json(os.path.join(plane, "topology.json"))
    topo = topo if isinstance(topo, dict) else {}
    mode = topo.get("mode") if topo.get("mode") in ("mono", "microservice") else "mono"
    lang = resolve_language(plane, topo)
    shared = topo.get("shared") is True
    entries = load_learnings(os.path.join(plane, "learnings.jsonl"))
    cli = os.path.join(plugin_root, "bin", "claudehut-index")
    head = [
        START,
        "# ClaudeHut memory index — %s" % name,
        "Budget: 8192 bytes for this whole file; this block (≤2048 B) is regenerated by `claudehut-index memory`.",
        "Hand-written notes go below the end marker. Older blocks: `MEMORY-history.md` (not @import-ed).",
        "",
        "- Plane: `%s` — PROJECT.md, LANGUAGE.md always loaded; the rest on demand" % plane,
        "- Topology: %s%s · language %s · sharing: %s" % (
            mode, (" · hub `%s`" % topo["hub"]) if mode == "microservice" and topo.get("hub") else "", lang,
            "committed to git (shared:true)" if shared else "local only (shared:false)"),
        "- Index (read-only): `%s status|brief|find|svc`" % cli,
        "- On demand: `learnings.jsonl` (%d live), `reuse-index.json` (legacy, read-only), `architecture.md`" % live_count(entries),
        "- Rules: `.claude/rules/*.md` load by path",
    ]
    tail = [END]
    tl = topics(entries)
    lines_t = ["", "## Topics", "category(trigger) → learnings.jsonl (entries):"] + [
        "- %s(%s) → learnings.jsonl (%d)" % (c, t, n) for c, t, n in tl] if tl else []

    def render(ls):
        return "\n".join(ls) + "\n"

    block = render(head + lines_t + tail)
    while len(block.encode("utf-8")) > BLOCK_MAX and len(lines_t) > 3:
        lines_t = lines_t[:-1]
        block = render(head + lines_t + tail)
    if len(block.encode("utf-8")) > BLOCK_MAX:  # pathological path lengths: drop the topics header too
        block = render(head + tail)
    if len(block.encode("utf-8")) > BLOCK_MAX:
        block = render([START, "# ClaudeHut memory index — %s" % name[:60], "- Plane: `.claude/claudehut`", END])
    return block


def split_sections(text):
    """[(heading_line_or_None, chunk_text)] split at '# ' / '## ' lines outside code fences."""
    out, cur_head, cur = [], None, []
    fence = False
    for line in text.splitlines(keepends=True):
        s = line.rstrip("\n")
        if s.lstrip().startswith("```"):
            fence = not fence
        if not fence and (s.startswith("# ") or s.startswith("## ")):
            out.append((cur_head, "".join(cur)))
            cur_head, cur = s, [line]
            continue
        cur.append(line)
    out.append((cur_head, "".join(cur)))
    return out


def is_machine(head):
    return bool(head) and bool(MACHINE_H1.match(head) or MACHINE_H2.match(head))


def atomic_write(path, data):
    d = os.path.dirname(path) or "."
    fd, tmp = tempfile.mkstemp(prefix=".mem.", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(data)
        try:  # mkstemp creates 0600: keep the file's own mode (0644 for a new one), as claudehut-migrate's restore expects
            os.chmod(tmp, os.stat(path).st_mode & 0o7777 if os.path.exists(path) else 0o644)
        except OSError:
            pass
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def main(argv):
    a = args_parse(argv)
    plane = a["plane"] or os.path.join(os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd(), ".claude", "claudehut")
    plane = os.path.abspath(plane)
    plugin_root = os.path.abspath(a["plugin_root"] or os.environ.get("CLAUDE_PLUGIN_ROOT")
                                  or os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    rep = {"file": os.path.join(plane, "MEMORY.md"), "action": "none"}
    if not os.path.isdir(plane):
        rep["action"] = "skip"; rep["reason"] = "no plane"
        return rep
    project_dir = os.path.dirname(os.path.dirname(plane))
    topo = read_json(os.path.join(plane, "topology.json"))
    name = (topo or {}).get("service") if isinstance(topo, dict) else None
    name = name or os.path.basename(project_dir) or "project"

    mem = os.path.join(plane, "MEMORY.md")
    hist = os.path.join(plane, "MEMORY-history.md")
    try:
        with open(mem, encoding="utf-8", errors="surrogateescape") as f:
            old = f.read()
    except FileNotFoundError:
        old = None
    block = build_block(plane, plugin_root, name)
    rep["bytes_before"] = len(old.encode("utf-8", "surrogateescape")) if old is not None else 0
    moved = ""

    if old is None:
        new = block
        rep["action"] = "create"
    elif START in old and END in old and old.index(START) < old.index(END):
        i, j = old.index(START), old.index(END) + len(END)
        rest = old[j:]
        if rest.startswith("\n"):
            rest = rest[1:]
        if a["migrate"]:
            secs = split_sections(rest)
            kept = [secs[0][1]] + [c for h, c in secs[1:] if not (h and PER_TASK_H2.match(h))]
            moved_parts = [c for h, c in secs[1:] if h and PER_TASK_H2.match(h)]
            if moved_parts:
                moved, rest = "".join(moved_parts), "".join(kept)
                rep["sections_moved"] = len(moved_parts)
                rep["bytes_moved"] = len(moved.encode("utf-8", "surrogateescape"))
        new = old[:i] + block + rest
        rep["action"] = "refresh"
    else:
        if not a["migrate"]:
            rep["action"] = "skip"; rep["reason"] = "legacy file without markers (--no-migrate)"
            return rep
        sections = split_sections(old)
        pre = sections[0][1]
        kept, moved_parts, n_moved = [], [], 0
        for head, chunk in sections[1:]:
            if is_machine(head):
                moved_parts.append(chunk); n_moved += 1
            else:
                kept.append(chunk)
        moved = "".join(moved_parts)
        body = "".join(kept)
        new = pre + block + ("\n" + body if body and not body.startswith("\n") else body)
        rep["action"] = "migrate"
        rep["sections_moved"] = n_moved
        rep["bytes_moved"] = len(moved.encode("utf-8", "surrogateescape"))

    rep["bytes_after"] = len(new.encode("utf-8", "surrogateescape"))
    rep["block_bytes"] = len(block.encode("utf-8"))
    rep["over_budget"] = rep["bytes_after"] > FILE_BUDGET
    if old is not None and new == old:
        rep["action"] = "unchanged"
        return rep
    if a["check"]:
        rep["dry_run"] = True
        return rep

    if moved:
        try:
            with open(hist, encoding="utf-8", errors="surrogateescape") as f:
                h_old = f.read()
        except FileNotFoundError:
            h_old = ""
        # Idempotent: a crash between the two writes must not duplicate history on the next run.
        if moved.strip() not in h_old:
            stamp = time.strftime("%Y-%m-%d", time.gmtime())
            hdr = "" if h_old else ("# MEMORY history — %s\n\nBlocks moved out of MEMORY.md. Not @import-ed; read on demand.\n" % name)
            sep = "" if (not h_old or h_old.endswith("\n")) else "\n"
            atomic_write(hist, h_old + sep + hdr + "\n<!-- moved from MEMORY.md by claudehut-index memory, %s -->\n" % stamp + moved)
    atomic_write(mem, new)
    return rep


def fmt(rep):
    if rep.get("action") in ("skip",):
        return "memory: skipped — %s" % rep.get("reason", "")
    s = "memory: %s %s %d B → %d B (block %d B)" % (
        rep["action"], rep["file"], rep.get("bytes_before", 0), rep.get("bytes_after", 0), rep.get("block_bytes", 0))
    if rep.get("sections_moved"):
        s += "; moved %d section(s), %d B to MEMORY-history.md" % (rep["sections_moved"], rep["bytes_moved"])
    if rep.get("over_budget"):
        s += "; OVER the 8192 B budget — the hand-written part is kept as is, trim it by hand"
    if rep.get("dry_run"):
        s += " (dry run)"
    return s


if __name__ == "__main__":
    js = "--json" in sys.argv[1:]
    try:
        r = main(sys.argv[1:])
    except Exception as ex:  # fail open: one line, exit 0
        r = {"action": "error", "reason": str(ex)[:200]}
        print(json.dumps(r) if js else "memory: error — %s" % r["reason"])
        sys.exit(0)
    print(json.dumps(r, ensure_ascii=False) if js else fmt(r))
    sys.exit(0)
