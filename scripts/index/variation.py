"""variation.py — variation-point detectors and the pattern miner for Java/Spring (pack lang-java-spring;
docs/v0.20 05 §2, M3a).

A variation point (VP) is a place where the code already chooses among variants of one concern. The decision
evals fail when an agent adds a new variant (a new message channel, a second bank) as a hard-coded one-off next to an
existing selector. These detectors find the selectors; `kb_variation_points` / `kb_patterns` serve them.

  D1 multi-impl     an interface / abstract class with >=2 concrete production BEAN subtypes      # see rule:d1-*
  D2 registry       a bean holding Map<K,X> / EnumMap<K,X> / List<X> / Set<X> / Collection<X> of a repo port X
  D3 factory        a *Factory/*Registry/*Resolver/*Selector/*Locator/*Dispatcher/*Router returning a repo port
  D4 conditional    >=1 bean variant of a port chosen by @ConditionalOnProperty / @ConditionalOnExpression / @Profile
  D8 contract-param a web endpoint parameter that names a variant (bank, provider, vendor, partner, channel, …)
  —  extension-point a GENERIC base type with >=2 bean subtypes (a framework hook): reported, never a VP or pattern
Not built yet (05 §2): D5 per-variant config, D6 branching on an enum/vendor string, D7 direct vendor injection.

Pattern miner: a port with D1 AND a selector (D2, D3 or D4) is an instance of the `port-selector` pattern; the
instance with the most variants is canonical. Every pattern is `candidate` until an owner confirms it (05 §2).

Deterministic, stdlib only, one rule per tagged line (`# rule:<name>`): evals/regress/variation-tests.sh deletes
each tagged line in turn and requires the score on the frozen fixture to drop, so no rule is dead weight.
Match rule for scoring (evals/fixtures/variation/expected.json): one VP = (anchor fqn, kind).
"""
import os
import re

from extract import PKG_RE, TYPE_DECL_RE, Src, leading_annotations, split_top

SCHEMA = 1
# Rule tables: one entry per line, so deleting any tagged line is valid Python and must lower the fixture score.
BEAN_ANN = set([
    "Component",  # rule:bean-component
    "Service",  # rule:bean-service
    "Repository",
])
PORT_RULES = [
    lambda t: t["kw"] == "interface",  # rule:port-interface
    lambda t: t["kw"] == "class" and t["abstract"],  # rule:port-abstract-class
]
VARIANT_RULES = [   # every rule must hold for a subtype to count as a production variant
    lambda t: t["kw"] in ("class", "record") and not t["abstract"],   # guard: an abstract bean is no variant (untested)
    lambda t: not t["test"],  # rule:variant-production-only
    lambda t: bool(t["ann"] & BEAN_ANN),  # rule:variant-is-bean
]
EXTENSION_RULES = [  # any rule → a framework extension point, not a variation point
    lambda p: p["generic"],  # rule:extension-generic
]
SELECTOR_SUFFIXES = [
    "Factory",  # rule:d3-factory-suffix
    "Registry", "Resolver", "Selector", "Locator", "Dispatcher", "Router",
]
COLLECTION_PATTERNS = [
    r"\b(?:Map|EnumMap|HashMap|LinkedHashMap|ConcurrentHashMap|SortedMap|TreeMap)\s*<\s*[\w.?\s]+,\s*([\w.]+)\s*>",  # rule:d2-map
    r"\b(?:List|Set|Collection|Iterable)\s*<\s*([\w.]+)\s*>",  # rule:d2-collection
]
CONDITIONAL_ANN = set([
    "ConditionalOnProperty",  # rule:d4-on-property
    "ConditionalOnExpression", "Profile",
])
VARIANT_PARAMS = [
    "bank",  # rule:d8-bank
    "provider", "vendor", "partner", "channel", "carrier", "gateway", "psp", "acquirer", "issuer", "telco", "network",
]
SELECTOR_KINDS = [   # what makes a multi-impl port an instance of port-selector
    "registry",  # rule:mine-registry
    "factory",  # rule:mine-factory
    "conditional",  # rule:mine-conditional
]
MIN_VARIANTS = 2
WEB_ANN = {"RestController", "Controller"}
MAPPING_ANN = {"GetMapping", "PostMapping", "PutMapping", "DeleteMapping", "PatchMapping", "RequestMapping"}
PARAM_ANN = {"RequestParam", "PathVariable", "RequestHeader"}
SELECTOR_NAME_RE = re.compile(r"(%s)$" % "|".join(SELECTOR_SUFFIXES or ["(?!)"]))
COLLECTION_RES = [re.compile(x) for x in COLLECTION_PATTERNS]
VARIANT_PARAM_RE = re.compile(r"^(%s)(code|id|name)?$" % "|".join(VARIANT_PARAMS or ["(?!)"]), re.I)
MOD_RE = re.compile(r"\b(abstract)\b")
JAVA_MAIN_RE = re.compile(r"(^|/)src/main/(.+/)?[^/]+\.java$")
JAVA_TEST_RE = re.compile(r"(^|/)src/test/(.+/)?[^/]+\.java$")
IMPORT_RE = re.compile(r"^\s*import\s+(?!static)([\w.]+)\s*;", re.M)
METHOD_RE = re.compile(r"([\w.]+(?:\s*<[^;{}()]*>)?(?:\s*\[\s*\])*)\s+([a-z_$][\w$]*)\s*\(")
FIELD_RE = re.compile(r"(?:(?:private|protected|public|final|static|transient|volatile)\s+)*([\w.]+\s*(?:<[^;{}()=]*>)?)\s+([a-z_$][\w$]*)\s*[;=]")


def _types_of(rel, text, test):
    src = Src(text)
    pm = PKG_RE.search(src.code)
    pkg = pm.group(1) if pm else ""
    imports = {i.split(".")[-1]: i for i in IMPORT_RE.findall(src.code)}
    found = []
    for m in TYPE_DECL_RE.finditer(src.skel):
        kw, name = m.group(1), m.group(2)
        body = src.skel.find("{", m.end())
        if body < 0 or (";" in src.skel[m.end():body] and kw != "record"):
            continue
        found.append({"kw": kw, "name": name, "at": m.start(), "body": body, "end": src.match(body, "{", "}"),
                      "ext": src.code[m.end():body]})
    out = []
    for t in found:
        outer = sorted([o for o in found if o["body"] < t["at"] < o["end"]], key=lambda o: o["body"])
        fqn = ".".join([x for x in [pkg] + [o["name"] for o in outer] + [t["name"]] if x])
        anns = leading_annotations(src, t["at"])
        mods = src.skel[(anns[-1][3] if anns else src.stmt_start(t["at"])):t["at"]]
        ext = re.sub(r"<[^<>]*(?:<[^<>]*>[^<>]*)*>", "", t["ext"])      # drop type arguments
        sup = []
        em = re.search(r"\bextends\s+(.+?)(?=\bimplements\b|$)", ext, re.S)
        im = re.search(r"\bimplements\s+(.+)$", ext, re.S)
        for grp in (em, im):
            if grp:
                sup += [s.strip() for s in grp.group(1).split(",") if s.strip()]
        inner = [(o["body"], o["end"]) for o in found if t["body"] < o["at"] < o["end"] and o is not t]
        members = _members(src, t, inner)
        out.append({"fqn": fqn, "name": t["name"], "kw": t["kw"], "file": rel, "line": src.line(t["at"]),
                    "test": test, "pkg": pkg, "imports": imports, "supers": sup,
                    "abstract": bool(MOD_RE.search(mods)), "ann": {a[0] for a in anns}, "ann_args": anns,
                    "generic": t["ext"].lstrip().startswith("<"),
                    "members": members})
    return out


def _members(src, t, inner):
    """Fields, constructor/method signatures at the type's own member depth: [{kind, type, name, params, ann, line}]."""
    depth = src.depth(t["body"]) + 1
    res = []
    body = src.skel[t["body"] + 1:t["end"]]
    off = t["body"] + 1

    def own(pos):
        return src.depth(pos) == depth and not any(a < pos < b for a, b in inner)

    for m in FIELD_RE.finditer(body):
        pos = off + m.start()
        if own(pos) and src.pdepth(pos) == src.pdepth(t["body"]):
            res.append({"kind": "field", "type": " ".join(m.group(1).split()), "name": m.group(2), "line": src.line(pos)})
    ctor_re = re.compile(r"\b" + re.escape(t["name"]) + r"\s*\(")
    for rx, kind in ((ctor_re, "ctor"), (METHOD_RE, "method")):
        for m in rx.finditer(body):
            pos = off + m.start()
            if not own(pos):
                continue
            popen = off + m.end() - 1
            close = src.match(popen, "(", ")")
            after = src.skel[close + 1:close + 200].lstrip()
            if not after.startswith(("{", "throws")) and not (kind == "method" and after.startswith(";")):
                continue
            if kind == "method" and m.group(1) in ("new", "return", "else", "throw"):
                continue
            params = []
            for p in split_top(src.code[popen + 1:close]):
                ptxt = re.sub(r"@[\w.]+(\s*\([^)]*\))?", " ", p)
                pm = re.match(r"\s*(?:final\s+)?([\w.]+\s*(?:<.*>)?(?:\[\])?)\s+([\w$]+)\s*$", ptxt, re.S)
                if pm:
                    params.append({"type": " ".join(pm.group(1).split()), "name": pm.group(2), "src": p})
            anns = leading_annotations(src, off + m.start())
            res.append({"kind": kind, "type": " ".join(m.group(1).split()) if kind == "method" else t["name"],
                        "name": m.group(2) if kind == "method" else t["name"], "params": params,
                        "ann": {a[0] for a in anns}, "line": src.line(pos)})
    return res


class Model:
    def __init__(self, types):
        self.types = types
        self.by_fqn = {t["fqn"]: t for t in types}
        self.by_simple = {}
        for t in types:
            self.by_simple.setdefault(t["name"], []).append(t)

    def resolve(self, name, ctx):
        """A type name as written in ctx's file → a repo type, or None (library / JDK / ambiguous)."""
        name = name.strip()
        if name in self.by_fqn:
            return self.by_fqn[name]
        simple = name.split(".")[-1]
        if simple in ctx["imports"]:
            return self.by_fqn.get(ctx["imports"][simple])
        same = self.by_fqn.get(f"{ctx['pkg']}.{simple}" if ctx["pkg"] else simple)
        if same:
            return same
        cands = [t for t in self.by_simple.get(simple, []) if not t["test"]]
        return cands[0] if len(cands) == 1 else None

    @staticmethod
    def is_port(t):
        return any(r(t) for r in PORT_RULES)

    @staticmethod
    def is_bean_variant(t):
        return all(r(t) for r in VARIANT_RULES)


def _loc(t, line=None):
    return {"fqn": t["fqn"], "file": t["file"], "line": line or t["line"]}


def parse_file(rel, text):
    """One file → its type records, JSON-serializable (the per-file cache unit), or [] when not a Java source."""
    test = bool(JAVA_TEST_RE.search(rel))
    if not (JAVA_MAIN_RE.search(rel) or test):
        return []
    try:
        out = _types_of(rel, text, test)
    except Exception:  # one unparsable file costs only itself
        return []
    for t in out:
        t["ann"] = sorted(t["ann"])
        t.pop("ann_args", None)
        for m in t["members"]:
            if "ann" in m:
                m["ann"] = sorted(m["ann"])
    return out


def detect(files, read, cache=None):
    """files: repo-relative paths; read(rel) → text; cache: {rel: types} already parsed (reused as is).
    → (variation_points, patterns)."""
    types = []
    for rel in files:
        recs = cache[rel] if cache is not None and rel in cache else parse_file(rel, read(rel))
        types += recs
    return analyze(types)


def analyze(types):
    for t in types:   # cached records carry lists; the detectors use sets
        t["ann"] = set(t["ann"])
        for m in t["members"]:
            if "ann" in m:
                m["ann"] = set(m["ann"])
    model = Model(types)
    subs = {}
    for t in types:
        for s in t["supers"]:
            p = model.resolve(s, t)
            if p is not None:
                subs.setdefault(p["fqn"], []).append(t)
    vps = {}

    def add(anchor, kind, **kw):
        key = (anchor["fqn"] if isinstance(anchor, dict) else anchor, kind)
        if key not in vps:
            base = _loc(anchor) if isinstance(anchor, dict) else {"fqn": anchor}
            vps[key] = dict({"anchor": key[0], "kind": kind, "file": base.get("file"), "line": base.get("line")}, **kw)
        return vps[key]

    ports = [t for t in types if not t["test"] and model.is_port(t)]
    for p in ports:
        variants = [s for s in subs.get(p["fqn"], []) if model.is_bean_variant(s)]
        if any(r(p) for r in EXTENSION_RULES) and len(variants) >= MIN_VARIANTS:
            # A generic base type (RequestHandler<T, R>, AbstractService<E, ID, R>, JsonConverter<T>) is a framework
            # extension point: its subtypes are features, not variants of one concern. Reported, never a VP or pattern.
            add(p, "extension-point", variants=[_loc(v) for v in variants][:5], count=len(variants))
            continue
        if len(variants) >= MIN_VARIANTS:
            add(p, "multi-impl", variants=[_loc(v) for v in variants])
        if any(v["ann"] & CONDITIONAL_ANN for v in variants) and len(variants) >= MIN_VARIANTS:
            add(p, "conditional", variants=[_loc(v) for v in variants if v["ann"] & CONDITIONAL_ANN])
    for t in types:
        if t["test"]:
            continue
        for m in t["members"] if t["ann"] & (BEAN_ANN | {"Configuration"}) else []:
            texts = [m["type"]] if m["kind"] == "field" else [p["type"] for p in m.get("params", [])]
            for tx in texts:
                for g in (g for rx in COLLECTION_RES for g in rx.finditer(tx)):
                    el = model.resolve(g.group(1), t)
                    if el is not None and model.is_port(el) and not el["test"] and not el["generic"]:
                        add(el, "registry", selector=_loc(t, m["line"]))
            if m["kind"] == "method" and SELECTOR_NAME_RE.search(t["name"]):
                rt = model.resolve(re.sub(r"<.*", "", m["type"]), t)
                if rt is not None and model.is_port(rt) and not rt["test"] and not rt["generic"]:
                    add(rt, "factory", selector=_loc(t, m["line"]))
        if t["ann"] & WEB_ANN:
            for m in t["members"]:
                if m["kind"] != "method" or not (m["ann"] & MAPPING_ANN):
                    continue
                for prm in m["params"]:
                    pa = re.findall(r"@(\w+)(?:\s*\(\s*(?:value\s*=\s*|name\s*=\s*)?\"([^\"]*)\")?", prm["src"])
                    if not any(a in PARAM_ANN for a, _ in pa):
                        continue
                    pname = next((v for a, v in pa if a in PARAM_ANN and v), "") or prm["name"]
                    if VARIANT_PARAM_RE.match(pname):
                        anchor = f"{t['fqn']}#{m['name']}({prm['name']})"
                        add(anchor, "contract-param", file=t["file"], line=m["line"], param=pname)
    out = sorted(vps.values(), key=lambda v: (v["anchor"], v["kind"]))
    return out, mine(out)


def mine(vps):
    """port-selector instances: an anchor with multi-impl AND a selector (registry | factory | conditional)."""
    by = {}
    for v in vps:
        by.setdefault(v["anchor"], {})[v["kind"]] = v
    inst = []
    for a, kinds in sorted(by.items()):
        if "extension-point" in kinds:
            continue
        if "multi-impl" in kinds and kinds.keys() & set(SELECTOR_KINDS):
            sel = next((kinds[k] for k in ("factory", "registry", "conditional") if k in kinds and k in SELECTOR_KINDS), None)
            inst.append({"id": f"port-selector/{a}", "anchor": a, "variants": len(kinds["multi-impl"].get("variants", [])),
                         "selector": (sel or {}).get("selector") or {"kind": "conditional"},
                         "variant_dir": os.path.dirname(kinds["multi-impl"]["variants"][0]["file"])})
    if not inst:
        return []
    canon = max(inst, key=lambda i: (i["variants"], i["anchor"]))
    return [{"id": "port-selector", "name": "Port + selector (one implementation per variant, chosen at runtime)",
             "status": "candidate", "instances": inst, "canonical": canon["anchor"],
             "recipe": ("Add the new variant as one class implementing the port, annotated like its siblings and "
                        "placed beside them; the existing selector (factory / registry / condition) picks it up. "
                        "Do not call a variant class directly from domain code.")}]
