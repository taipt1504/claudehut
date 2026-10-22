"""K10 pack registry and activation (docs/v0.20 07 §1, ADR K-02; M2a).

A pack is declared by packs/<name>/claudehut-pack.json. In M2a every pack still ships inside the one `claudehut`
plugin, so the registry is the plugin's own packs/ dir; the physical split into separate plugins (bundle +
`dependencies`) keeps the same manifests and adds `register` from each pack's SessionStart hook.

detect (evaluated against the project, read-only, bounded):
  {"always": true}                 always active (kernel, workflow, review)
  {"any": [pattern, …]}            active when one pattern exists: a literal path at any depth ("pom.xml",
                                   "src/main/java"; one stat), or a root/one-level glob ("*.py", "*/pom.xml"). Never
                                   a recursive walk: SessionStart-safe
  {"deps": [substring, …]}         active when a root or one-level-down build file mentions the substring
A pack with several keys is active when ANY key matches. CLAUDEHUT_PACKS="+name,-name" forces a pack on or off
(the user's override; recorded in the result so it is never silent).
"""
import fnmatch
import hashlib
import json
import os

from . import plane

REQUIRED = {"pack", "version", "kernel", "kind", "detect", "owns"}
KEYS = REQUIRED | {"$schema", "description", "rules", "plane_templates", "guides", "sensors", "invariants", "evals"}
BUILD_FILES = ("pom.xml", "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts",
               "gradle/libs.versions.toml", "pyproject.toml", "package.json")


def plugin_root():
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))


def load(root=None):
    """All manifests under <root>/packs/*/claudehut-pack.json → {name: manifest}. A broken manifest is reported."""
    root = root or plugin_root()
    out, errors = {}, []
    base = os.path.join(root, "packs")
    for name in sorted(os.listdir(base)) if os.path.isdir(base) else []:
        p = os.path.join(base, name, "claudehut-pack.json")
        if not os.path.isfile(p):
            continue
        try:
            with open(p, encoding="utf-8") as f:
                m = json.load(f)
        except (OSError, ValueError) as exc:
            errors.append({"pack": name, "error": f"unreadable manifest: {exc}"})
            continue
        if not isinstance(m, dict) or m.get("pack") != name:
            errors.append({"pack": name, "error": "manifest `pack` must equal its directory name"})
            continue
        unknown = sorted(set(m) - KEYS)
        missing = sorted(REQUIRED - set(m))
        if unknown or missing:   # packs/claudehut-pack.schema.json, checked without a schema library
            errors.append({"pack": name, "error": f"manifest keys: missing {missing}, unknown {unknown}"})
            continue
        m["_dir"] = os.path.join(base, name)
        out[name] = m
    return out, errors


def _top(project):
    """Root entries plus one level down — the only places detect looks (no recursive walk)."""
    names = []
    try:
        for e in os.listdir(project):
            if e.startswith(".git"):
                continue
            names.append(e)
            sub = os.path.join(project, e)
            if os.path.isdir(sub) and not e.startswith("."):
                try:
                    names += [f"{e}/{s}" for s in os.listdir(sub)]
                except OSError:
                    pass
    except OSError:
        pass
    return names


def _deps_text(project):
    chunks = []
    for rel in BUILD_FILES:
        for cand in [rel] + [f"{d}/{rel}" for d in _subdirs(project)]:
            p = os.path.join(project, cand)
            if os.path.isfile(p):
                try:
                    with open(p, encoding="utf-8", errors="replace") as f:
                        chunks.append(f.read(200000))
                except OSError:
                    pass
    return "\n".join(chunks)


def _subdirs(project):
    try:
        return [e for e in os.listdir(project) if not e.startswith(".") and os.path.isdir(os.path.join(project, e))]
    except OSError:
        return []


def _forced():
    on, off = set(), set()
    for tok in (os.environ.get("CLAUDEHUT_PACKS") or "").split(","):
        tok = tok.strip()
        if tok.startswith("+"):
            on.add(tok[1:])
        elif tok.startswith("-"):
            off.add(tok[1:])
    return on, off


def evaluate(project, manifests):
    """→ [{pack, active, why}] in name order."""
    top = None
    deps = None
    on, off = _forced()
    res = []
    for name, m in sorted(manifests.items()):
        d = m.get("detect") or {}
        why = ""
        if d.get("always") is True:
            why = "always"
        if not why and d.get("any"):
            top = _top(project) if top is None else top
            for pat in d["any"]:
                if not any(c in pat for c in "*?[") and os.path.exists(os.path.join(project, pat)):
                    why = f"found {pat}"   # a literal path (any depth, e.g. src/main/java): one stat, no walk
                    break
                hit = next((t for t in top if fnmatch.fnmatchcase(t, pat)), None)
                if hit:
                    why = f"found {hit}"
                    break
        if not why and d.get("deps"):
            deps = _deps_text(project) if deps is None else deps
            hit = next((s for s in d["deps"] if s in deps), None)
            if hit:
                why = f"build file mentions {hit}"
        active = bool(why)
        if name in on:
            active, why = True, "forced on by CLAUDEHUT_PACKS"
        elif name in off:
            active, why = False, "forced off by CLAUDEHUT_PACKS"
        res.append({"pack": name, "active": active, "why": why or "no detect key matched",
                    "kind": m.get("kind"), "version": m.get("version")})
    return res


def registry(project):
    """<plane>/state/packs/<pack>.json, written by each pack-shipping plugin's SessionStart hook (register-packs.sh,
    07 §1.1) → {pack: entry + status}. status: ok | stale (that root or its manifest is gone, or the manifest
    changed since it registered — the session runs an older install than the one on disk)."""
    d = os.path.join(plane.plane_dir(project), "state", "packs")
    out = {}
    for f in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        if not f.endswith(".json"):
            continue
        e = plane.read_json(os.path.join(d, f))
        if not isinstance(e, dict) or e.get("pack") != f[:-5] or not isinstance(e.get("root"), str):
            continue
        mp = os.path.join(e["root"], "packs", e["pack"], "claudehut-pack.json")
        status = "ok"
        if not os.path.isfile(mp):
            status = "stale"
        elif e.get("manifest_hash"):
            with open(mp, "rb") as fh:
                if hashlib.sha256(fh.read()).hexdigest() != e["manifest_hash"]:
                    status = "stale"
        out[e["pack"]] = dict(e, status=status)
    return out


def load_all(project, root=None):
    """This plugin's manifests plus the packs other plugins registered for the project (a split install).
    → (manifests, errors, registration {pack: registered|unregistered|stale|foreign}). A pack this plugin carries
    always loads from here; a foreign one loads from its registered root while that entry is ok."""
    root = root or plugin_root()
    manifests, errors = load(root)
    reg = registry(project)
    status = {}
    for name in manifests:
        e = reg.get(name)
        status[name] = "unregistered" if not e else ("stale" if e["status"] == "stale" else "registered")
    for name, e in reg.items():
        if name in manifests:
            continue
        if e["status"] != "ok":
            status[name] = "stale"
            continue
        other, errs = load(e["root"])
        if name in other:
            manifests[name] = other[name]
            status[name] = "foreign"
        errors += [x for x in errs if x.get("pack") == name]
    return manifests, errors, status


def active_names(project, root=None):
    manifests, _ = load(root)
    return [r["pack"] for r in evaluate(project, manifests) if r["active"]]


def owner_map(root=None):
    """{owned glob: pack} — for the ownership conformance check (every shipped file belongs to exactly one pack)."""
    manifests, _ = load(root)
    return {g: n for n, m in manifests.items() for g in m.get("owns") or []}


def owners_of(rel, manifests):
    out = []
    for n, m in manifests.items():
        for g in m.get("owns") or []:
            if g.endswith("/**"):
                if rel == g[:-3] or rel.startswith(g[:-2]):
                    out.append(n)
                    break
            elif fnmatch.fnmatchcase(rel, g):
                out.append(n)
                break
    return out
