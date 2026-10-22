"""vendor-leak sensor (K7; docs/v0.20 06 §2 `vendor-leak`, appendix a2 R3). Advisory: it reports, never blocks.

A vendor name in a neutral place (an enum constant, a DB column or table, a field of an entity or of a
@ConfigurationProperties class, a properties prefix, a domain/model package) ties the domain to one vendor; the
vendor belongs in its adapter or in configuration keyed by it (application.yml `providers.<vendor>.*` is the vendor
kept as data, so YAML is not scanned).

Vendors come from two places, never from a hard-coded list (the public plugin ships no vendor names):
  1. the owner's list: <plane>/vendors.txt, and vendors.txt in an active pack's dir (one name per line, '#' comments);
  2. the index: variant classes of an external-looking port family in <plane>/index/variation.json, minus the port
     name (CmcSmsProvider − SmsProvider → cmc). A port is external-looking when its name ends in Provider, Client,
     Sender, Gateway, Adapter, Exporter, Connector, Notifier or Integration; QrStrategy's Static/Dynamic are not
     vendors. A variant whose name does not end in the port name, or whose rest is a stop word, gives nothing.
The adapters are not neutral: the derived families' variant dirs, and a package named after a vendor outside
domain/model/entity/core (how an owner-listed vendor's adapter is recognised). Only src/main code and *.sql files
are scanned; tests never are.
"""
import json
import os
import re

from . import packs, plane

EXTERNAL_PORT_RE = re.compile(r"(Provider|Client|Sender|Gateway|Adapter|Exporter|Connector|Notifier|Integration)$")
NOT_VENDOR = {"sms", "email", "mail", "push", "bank", "http", "rest", "grpc", "kafka", "default", "static", "dynamic",
              "mock", "fake", "stub", "noop", "dummy", "test", "legacy", "internal", "external", "base", "simple",
              "generic", "composite", "delegating", "caching", "retrying", "logging", "local", "remote", "async",
              "sync", "batch", "web", "api", "new", "old", "v1", "v2"}
NEUTRAL_PKG = {"domain", "model", "entity", "entities", "core"}
DATA_ANN_RE = re.compile(r"@(Entity|Embeddable|MappedSuperclass|Table|Document|ConfigurationProperties)\b")
SKIP_DIRS = {".git", "build", "target", "out", "node_modules", ".gradle", ".idea", ".claudehut", ".claude"}
MAX_FILES = 20000


def tokens(ident):
    """fptMessageId → [fpt, message, id]; FPT_ACCEPTED → [fpt, accepted]; notify.sms → [notify, sms]."""
    parts = re.split(r"[^A-Za-z0-9]+", ident)
    out = []
    for p in parts:
        out += [t.lower() for t in re.findall(r"[A-Z]+(?![a-z])|[A-Z]?[a-z]+|[0-9]+", p)]
    return out


def _read_list(path):
    try:
        with open(path, encoding="utf-8") as f:
            return [l.split("#", 1)[0].strip() for l in f if l.split("#", 1)[0].strip()]
    except OSError:
        return []


def vendors(project):
    """→ (vendors {token: source}, adapter_dirs {repo-relative dir}, families 'ok'|'unknown')."""
    pd = plane.plane_dir(project)
    found, adapters = {}, set()
    for name in _read_list(os.path.join(pd, "vendors.txt")):
        found.setdefault(name.lower(), "vendors.txt")
    manifests, _ = packs.load()
    for r in packs.evaluate(project, manifests):
        if r["active"]:
            for name in _read_list(os.path.join(manifests[r["pack"]]["_dir"], "vendors.txt")):
                found.setdefault(name.lower(), f"pack {r['pack']}")
    vj = plane.read_json(os.path.join(pd, "index", "variation.json"))
    if not isinstance(vj, dict):   # never indexed: only the owner's list applies, and the report says so
        return found, adapters, "unknown"
    for vp in vj.get("variation_points") or []:
        if vp.get("kind") != "multi-impl":
            continue
        port = vp["anchor"].rsplit(".", 1)[-1]
        stem = port[len("Abstract"):] if port.startswith("Abstract") else port
        if not EXTERNAL_PORT_RE.search(stem):
            continue
        for v in vp.get("variants") or []:
            name = (v.get("fqn") or "").rsplit(".", 1)[-1]
            rest = name[:-len(stem)] if name.endswith(stem) else ""
            if rest and rest.isalnum() and rest.lower() not in NOT_VENDOR and len(rest) >= 2:
                found.setdefault(rest.lower(), f"variant of {port}")
                if v.get("file"):
                    adapters.add(os.path.dirname(v["file"]))
    return found, adapters, "ok"


def _files(project, paths):
    out = []
    roots = [plane.abspath(project, p) for p in paths] if paths else [project]
    for r in roots:
        if os.path.isfile(r):
            out.append(r)
            continue
        for d, ds, fs in os.walk(r):
            ds[:] = [x for x in ds if x not in SKIP_DIRS]
            out += [os.path.join(d, f) for f in fs if f.endswith((".java", ".sql"))]
            if len(out) > MAX_FILES:
                return out[:MAX_FILES]
    return out


def _line_of(text, pos):
    return text.count("\n", 0, pos) + 1


def scan_java(rel, text, vset):
    hits = []

    def hit(kind, ident, pos):
        for t in tokens(ident):
            if t in vset:
                hits.append({"file": rel, "line": _line_of(text, pos), "kind": kind, "vendor": t, "text": ident})

    m = re.search(r"^\s*package\s+([\w.]+)\s*;", text, re.M)
    if m:
        segs = m.group(1).split(".")
        if not NEUTRAL_PKG & set(segs) and any(x.lower() in vset for x in segs):
            return []   # a package named after the vendor, outside domain/model/…: that vendor's adapter
        if NEUTRAL_PKG & set(segs):
            for s in segs:
                if s.lower() in vset:
                    hits.append({"file": rel, "line": _line_of(text, m.start(1)), "kind": "package", "vendor": s.lower(),
                                 "text": m.group(1)})
    for em in re.finditer(r"\benum\s+\w+[^{]*\{([^;}]*)", text):
        body, base = em.group(1), em.start(1)
        body_nc = re.sub(r"\([^)]*\)", lambda x: " " * len(x.group(0)), body)   # constructor args are not names
        for c in re.finditer(r"(?:^|,)\s*(?:@\w+\s*)*([A-Za-z_]\w*)", body_nc):
            hit("enum-constant", c.group(1), base + c.start(1))
    for cm in re.finditer(r"@(?:Column|JoinColumn|Table)\s*\([^)]*?\bname\s*=\s*\"([^\"]+)\"", text):
        hit("column", cm.group(1), cm.start(1))
    for pm in re.finditer(r"@ConfigurationProperties\s*\(\s*(?:(?:prefix|value)\s*=\s*)?\"([^\"]+)\"", text):
        hit("properties-prefix", pm.group(1), pm.start(1))
    if DATA_ANN_RE.search(text):
        for fm in re.finditer(r"^\s*(?:@\w+(?:\([^)]*\))?\s*)*(?:private|protected|public)\s+(?!static\b)(?:final\s+)?"
                              r"[\w.<>,?\[\] ]+?\s+(\w+)\s*(?:=[^;]*)?;", text, re.M):
            hit("field", fm.group(1), fm.start(1))
    return hits


def scan_sql(rel, text, vset):
    hits = []

    def hit(kind, ident, pos):
        for t in tokens(ident):
            if t in vset:
                hits.append({"file": rel, "line": _line_of(text, pos), "kind": kind, "vendor": t, "text": ident})

    for m in re.finditer(r"\bADD\s+(?:COLUMN\s+)?(?:IF\s+NOT\s+EXISTS\s+)?[`\"]?(\w+)", text, re.I):
        hit("column", m.group(1), m.start(1))
    for m in re.finditer(r"\bCREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?[`\"]?([\w.]+)[`\"]?\s*\((.*?)\)\s*;", text,
                         re.I | re.S):
        hit("table", m.group(1), m.start(1))
        for c in re.finditer(r"(?:^|,)\s*[`\"]?(\w+)", m.group(2)):
            if c.group(1).upper() not in ("PRIMARY", "CONSTRAINT", "UNIQUE", "FOREIGN", "KEY", "INDEX", "CHECK"):
                hit("column", c.group(1), m.start(2) + c.start(1))
    return hits


def scan(project, paths=None):
    found, adapters, families = vendors(project)
    vset = set(found)
    findings = []
    for f in _files(project, paths) if vset else []:
        rel = os.path.relpath(f, project)
        if f.endswith(".java"):
            if "/src/main/java/" not in "/" + rel or os.path.dirname(rel) in adapters:
                continue
            scan_fn = scan_java
        elif f.endswith(".sql"):
            if "/src/test/" in "/" + rel:
                continue
            scan_fn = scan_sql
        else:
            continue
        try:
            with open(f, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
        except OSError:
            continue
        findings += scan_fn(rel, text, vset)
    seen, out = set(), []
    for h in findings:
        k = (h["file"], h["line"], h["kind"], h["vendor"])
        if k not in seen:
            seen.add(k)
            h["fix"] = (f"'{h['vendor']}' ({found[h['vendor']]}) in a neutral {h['kind']}: name it by the role "
                        f"(e.g. provider_message_id) and keep the vendor as data or inside its adapter.")
            out.append(h)
    return {"vendors": [{"name": n, "source": s} for n, s in sorted(found.items())], "families": families,
            "findings": out}
