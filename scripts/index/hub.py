"""hub.py — the microservice hub of claudehut-index (07-index-memory.md §4.3, AC-8..AC-10; ADR-IDX-3/4).

python3 stdlib only. The hub aggregates per-service contracts into cross-service edges with evidence. It reads
service repos and never writes into them (no .claude/, no .understand-anything/, no git lock: every git call runs
with GIT_OPTIONAL_LOCKS=0).

Layout (<HUB> is the hub root, e.g. <workspace>/ewallet-knowledge; H = <HUB>/.claude/claudehut/hub):
  H/hub.json              {schema:1, language?}      init writes language; the hub only creates {schema:1}
  H/services.json         {"<svc>": {path, remote, indexed_commit, synced_at, has_plane}}  path relative to <HUB>
  H/aliases.json          {env:{}, topic_owner:{}, db_owner:{}, lib_owner:{}, _suggested:{…}}  user-owned
  H/links/<svc>.json      per-service contracts (+ resolved kafka topics, compact components) — plane or hub-scan
  H/service-links.json    {schema:1, edges:[{from,to,type,via,evidence[],confidence}], unresolved:[…]}  no timestamps
  H/HUB.md                ≤3 KB, paths from <HUB>
  H/.understand-anything/knowledge-graph.json + meta.json   service-level graph in UA schema (GRAPH_DIR = H)

Join rules (07 §4.3 table):
  http   client env / resolved client property → service: aliases.env wins (high); default-URL host == service
         (high); env stripped of _SERVICE_URL|_BASE_URL|_URL|_URI and _MS, kebab == <x>|<x>-ms (high); a property
         key segment == <x>|<x>-ms (high); a unique substring match (medium); a dotted host → external:<host>;
         else unresolved. Only entries with an http(s) default or an env ending _URL/_URI count as HTTP clients.
  kafka  consumer topics come from @KafkaListener (literal, ${prop:default}, same-file constant, SpEL
         #{'${prop:default}'.split(',')}) resolved against application*.yml; producer topics from KafkaTemplate
         literals / @Value fields (high), from yml topic keys not under a consumer path and not consumed by the same
         service (medium), and outbox topic-prefix (prefix match, medium). Exact == high unless the producer side is
         a yml heuristic; no producer → unresolved; a prefix no consumer matches → unresolved.
  lib    io.f8a.summer:* (or any group in aliases.lib_owner / a service's gradle `group=`) → owner service, high.
  db     one database name in ≥2 services → shared-db edge non-owner → owner (aliases.db_owner, else the only
         service with Flyway migrations): medium; no single owner: low. Reflects in-repo defaults only.
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import extract  # noqa: E402

SCHEMA = 1
HUB_MD_MAX = 3072
LOCK_STALE_S = 120
CONF_W = {"high": 1, "medium": 0.6, "low": 0.3}
DEFAULT_LIB_OWNER = {"io.f8a.summer": "java-common-ms"}
LOCAL_HOSTS = {"localhost", "127.0.0.1", "0.0.0.0", "host.docker.internal", ""}
NON_HTTP_ENV = re.compile(r"(^|_)(R2DBC|FLYWAY|DATASOURCE|JDBC|REDIS|KAFKA|RABBITMQ|MONGODB?|LIQUIBASE)(_|$)")
NON_HTTP_SCHEME = re.compile(r"^(r2dbc|jdbc|redis|rediss|mongodb|amqp|amqps|kafka|tcp|file|classpath):", re.I)
TOPIC_SKIP_LEAF = {"offset-storage-topic", "schema-history-topic", "topic-prefix"}
ALIAS_KEYS = ("env", "topic_owner", "db_owner", "lib_owner")
DB_SKIP_SEG = {"cdc", "flyway", "liquibase", "debezium"}
GITIGNORE = ("links/", "service-links.json", ".understand-anything/", ".lock/", "aliases.suggested.json", ".aliases.sha1")


# ---------------------------------------------------------------- helpers -----------------------------------
def git(repo, *args):
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0", LC_ALL="C")
    try:
        r = subprocess.run(["git", "-C", repo] + list(args), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           env=env, timeout=30)
    except Exception:
        return None
    return r.stdout.decode("utf-8", "replace") if r.returncode == 0 else None


def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default


def dumps(obj):
    return json.dumps(obj, ensure_ascii=False, indent=1, sort_keys=True) + "\n"


def write_atomic(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def write_if_changed(path, text):
    try:
        with open(path, encoding="utf-8") as f:
            if f.read() == text:
                return False
    except OSError:
        pass
    write_atomic(path, text)
    return True


def sha1_text(t):
    return hashlib.sha1(t.encode("utf-8")).hexdigest()


def clip(text, budget):
    b = text.encode("utf-8")
    if len(b) <= budget:
        return text
    return b[:max(0, budget - 4)].decode("utf-8", "ignore").rstrip() + " …"


# ---------------------------------------------------------------- hub location --------------------------------
def hub_dir(path, base=None):
    """A hub root (<HUB>/.claude/claudehut/hub) or the hub dir itself; relative paths resolve against base
    (the service repo root), as memory.resolve_language does."""
    if not path:
        return None
    p = path if os.path.isabs(path) else os.path.normpath(os.path.join(base or os.getcwd(), path))
    if os.path.basename(p.rstrip("/")) == "hub" and (os.path.isfile(os.path.join(p, "hub.json"))
                                                    or os.path.basename(os.path.dirname(p.rstrip("/"))) == "claudehut"):
        return os.path.realpath(p) if os.path.exists(p) else p
    root = os.path.realpath(p) if os.path.exists(p) else p
    return os.path.join(root, ".claude", "claudehut", "hub")


def hub_root(h):
    """H = <HUB>/.claude/claudehut/hub → <HUB>."""
    return os.path.dirname(os.path.dirname(os.path.dirname(h)))


def find_hub(plane, topo, explicit=None):
    """--hub, CLAUDEHUT_HUB, topology.json.hub, or the plane's own hub/ (a session opened at the hub root)."""
    base = os.path.dirname(os.path.dirname(plane))
    for cand in (explicit, os.environ.get("CLAUDEHUT_HUB"), (topo or {}).get("hub")):
        if cand:
            return hub_dir(cand, base)
    own = os.path.join(plane, "hub")
    if os.path.isfile(os.path.join(own, "services.json")) or os.path.isfile(os.path.join(own, "hub.json")):
        return own
    return None


class Lock:
    def __init__(self, h):
        self.path = os.path.join(h, ".lock")
        self.ok = False

    def __enter__(self):
        for _ in range(2):
            try:
                os.mkdir(self.path)
                self.ok = True
                return self
            except FileExistsError:
                try:
                    if time.time() - os.stat(self.path).st_mtime < LOCK_STALE_S:
                        return self
                except OSError:
                    continue
                shutil.rmtree(self.path, ignore_errors=True)
        return self

    def __exit__(self, *a):
        if self.ok:
            shutil.rmtree(self.path, ignore_errors=True)


# ---------------------------------------------------------------- service loading -----------------------------
def repo_top(path):
    top = git(path, "rev-parse", "--show-toplevel")
    return os.path.realpath(top.strip()) if top else os.path.realpath(path)


def svc_name(repo):
    plane = os.path.join(repo, ".claude", "claudehut")
    t = read_json(os.path.join(plane, "topology.json"), {}) or {}
    m = read_json(os.path.join(plane, "index", "meta.json"), {}) or {}
    return t.get("service") or m.get("svc") or os.path.basename(repo.rstrip("/"))


def list_repo_files(repo):
    out = git(repo, "ls-files", "-z", "-co", "--exclude-standard")
    if out is not None:
        files = [p for p in out.split("\0") if p]
    else:
        files = []
        for d, dirs, fs in os.walk(repo):
            dirs[:] = [x for x in dirs if x not in (".git", "build", "target", ".gradle", "node_modules", ".claude")]
            files += [os.path.relpath(os.path.join(d, f), repo) for f in fs]
    return sorted(p for p in files if not p.startswith(".claude/") and os.path.isfile(os.path.join(repo, p)))


def read_rel(repo, rel):
    try:
        with open(os.path.join(repo, rel), encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return None


def scan_repo(repo, svc):
    """hub-scan: extract rows + contracts in memory from a repo without a plane. Read-only."""
    files = list_repo_files(repo)
    rows, texts = [], {}
    for p in files:
        if extract.is_source(p):
            t = read_rel(repo, p)
            if t is not None:
                try:
                    rows.extend(extract.extract_file(p, t, svc))
                except Exception as e:  # one unparsable file never fails the scan
                    sys.stderr.write("hub-scan %s: %s\n" % (p, e))
        elif extract.is_contract_input(p):
            t = read_rel(repo, p)
            if t is not None:
                texts[p] = t
    rows = extract.sort_rows(rows)
    return rows, extract.extract_contracts(rows, texts), files


def load_plane(repo):
    idx = os.path.join(repo, ".claude", "claudehut", "index")
    meta = read_json(os.path.join(idx, "meta.json"))
    contracts = read_json(os.path.join(idx, "contracts.json"))
    if not isinstance(meta, dict) or not isinstance(contracts, dict):
        return None
    rows = []
    try:
        with open(os.path.join(idx, "components.jsonl"), encoding="utf-8") as f:
            for ln in f:
                if ln.strip():
                    try:
                        rows.append(json.loads(ln))
                    except ValueError:
                        pass
    except OSError:
        pass
    return meta, rows, contracts


def yml_files(repo, files=None):
    files = files if files is not None else list_repo_files(repo)
    out = {}
    for p in files:
        if extract.is_contract_input(p) and p.endswith((".yml", ".yaml")):
            t = read_rel(repo, p)
            if t is not None:
                out[p] = extract.yml_flat(t)
    return out


def placeholder_values(expr, flat):
    """'${a.b:x,y}' / "#{'${a.b:x}'.split(',')}" / a literal → ([topics], yml_at|None). Placeholders resolve against
    application*.yml (whose value may itself be ${ENV:default}); the in-code default is the fallback."""
    refs = extract.YML_REF_RE.findall(expr or "")
    if not refs:
        lit = (expr or "").strip()
        if not lit or lit.startswith("#{") or not re.fullmatch(r"[A-Za-z0-9_.,\- ]+", lit):
            return [], None
        return [t.strip() for t in lit.split(",") if t.strip()], None
    vals, at = [], None
    for prop, dflt in refs:
        val = None
        if not prop.isupper():
            rel, e = extract.yml_lookup(flat, prop)
            if e:
                inner = extract.YML_REF_RE.search(e["value"])
                val = (inner.group(2) if inner else e["value"]) or None
                at = at or "%s:%d" % (rel, e["line"])
        val = val if val is not None else (dflt or None)
        if val:
            vals += [t.strip() for t in val.split(",") if t.strip() and "${" not in t]
    return vals, at


def listener_exprs(repo, rel, line):
    """Raw topic expressions of the @KafkaListener whose '@' is on `line` of rel; same-file constants resolved."""
    text = read_rel(repo, rel)
    if text is None:
        return []
    src = extract.Src(text)
    consts = dict(extract.CONST_RE.findall(src.code))
    out = []
    for name, args, at, _e in extract.annotations(src, 0, len(src.skel)):
        if name not in extract.LISTENER_ANN or src.line(at) != line:
            continue
        for key in ("topics", "value", "topicPattern"):
            raw = (args or {}).get(key, "").strip()
            if not raw:
                continue
            lits = extract.strings(raw)
            if lits and raw.lstrip("{ ").startswith('"'):
                out += lits
            else:
                for ident in re.findall(r"[A-Za-z_][\w.]*", raw.strip("{} ")):
                    v = consts.get(ident.split(".")[-1])
                    if v is not None:
                        out.append(v)
        break
    return out


def value_field_expr(repo, rel, ident):
    """topic_expr `ident` of a producer → the @Value("${…}") or constant expression that defines it (same file)."""
    text = read_rel(repo, rel)
    if text is None:
        return None
    ident = ident.split(".")[-1].strip("() ")
    if not re.fullmatch(r"\w+", ident or ""):
        return None
    m = re.search(r'@Value\s*\(\s*"([^"]*)"\s*\)\s*(?:(?:private|protected|public|final|static)\s+)*[\w.<>]+\s+%s\b'
                  % re.escape(ident), text)
    if m:
        return m.group(1)
    for n, v in extract.CONST_RE.findall(text):
        if n == ident:
            return v
    return None


def kafka_sides(repo, rows, contracts, flat):
    """→ (consumes[{topic, at[], src}], produces[{topic|prefix, at[], conf}], unresolved[])."""
    consumes, produces, unresolved = [], [], []
    used_props = set()
    for r in rows:
        if r.get("kind") != "listener":
            continue
        at = "%s:%d" % (r["file"], r["line"])
        exprs = []
        if r.get("topic_prop"):
            exprs = ["${%s}" % r["topic_prop"]] if not r.get("topic") else ["${%s:%s}" % (r["topic_prop"], r["topic"])]
        elif r.get("topic_ref"):  # reactor-kafka receiver: props field → its @ConfigurationProperties yml key
            prop = extract.receiver_topic_prop(r, rows, flat)
            exprs = ["${%s}" % prop] if prop else []
        elif r.get("topic"):
            exprs = [r["topic"]]
        else:
            exprs = listener_exprs(repo, r["file"], r["line"])
        topics, yat = [], None
        for e in exprs:
            for prop, _d in extract.YML_REF_RE.findall(e):
                used_props.add(extract.relax(prop))
            ts, a = placeholder_values(e, flat)
            topics += ts
            yat = yat or a
        if not topics:
            unresolved.append({"kind": "kafka_consume", "at": at, "expr": (exprs[0] if exprs else None)})
            continue
        for t in dict.fromkeys(topics):
            consumes.append({"topic": t, "at": [x for x in (at, yat) if x]})
    # reactor-kafka KafkaReceiver & co.: a yml topic key under a consumer path no listener reads is a consumer too
    # (medium, the yml line is the evidence) — the mirror of the producer yml fallback below.
    for rel in sorted(flat):
        for e in flat[rel]:
            parts = [p.lower() for p in e["prop"].split(".")]
            if "topic" not in parts[-1] or parts[-1] in TOPIC_SKIP_LEAF or extract.relax(e["prop"]) in used_props:
                continue
            if not any(p in ("consumer", "consumers") for p in parts[:-1]) or any(p in ("dlt", "retry") for p in parts):
                continue
            inner = extract.YML_REF_RE.search(e["value"])
            val = (inner.group(2) if inner else e["value"]) or ""
            have = {c["topic"] for c in consumes}
            for v in [t.strip() for t in val.split(",") if re.fullmatch(r"[A-Za-z0-9_.\-]+", t.strip())]:
                if v not in have:
                    consumes.append({"topic": v, "at": ["%s:%d" % (rel, e["line"])], "conf": "medium"})
    consumed = {c["topic"] for c in consumes}
    for r in rows:
        if r.get("kind") != "producer":
            continue
        at = "%s:%d" % (r["file"], r["line"])
        if r.get("topic"):
            produces.append({"topic": r["topic"], "at": [at], "conf": "high"})
            continue
        expr = r.get("topic_expr")
        ts, yat = [], None
        if expr:
            fe = value_field_expr(repo, r["file"], expr) if not expr.startswith('"') else None
            if fe:
                for prop, _d in extract.YML_REF_RE.findall(fe):
                    used_props.add(extract.relax(prop))
                ts, yat = placeholder_values(fe, flat)
        for t in ts:
            produces.append({"topic": t, "at": [x for x in (at, yat) if x], "conf": "high"})
        if not ts and expr:
            unresolved.append({"kind": "kafka_produce", "at": at, "expr": expr[:80]})
    for rel in sorted(flat):
        for e in flat[rel]:
            parts = e["prop"].split(".")
            leaf = parts[-1].lower()
            if "topic" not in leaf:
                continue
            at = "%s:%d" % (rel, e["line"])
            inner = extract.YML_REF_RE.search(e["value"])
            val = (inner.group(2) if inner else e["value"]) or ""
            vals = [t.strip() for t in val.split(",") if re.fullmatch(r"[A-Za-z0-9_.\-]+", t.strip())]
            if leaf == "topic-prefix":
                for v in vals:
                    produces.append({"prefix": v, "at": [at], "conf": "medium"})
                continue
            if leaf in TOPIC_SKIP_LEAF or any(p.lower() in ("consumer", "consumers", "dlt", "retry") for p in parts[:-1]):
                continue
            if extract.relax(e["prop"]) in used_props:
                continue
            for v in vals:
                if v not in consumed:
                    produces.append({"topic": v, "at": [at], "conf": "medium"})
    return consumes, produces, unresolved


def lib_group(repo, files):
    """The Maven group a repo publishes (gradle.properties / build.gradle `group`), or None."""
    for rel in ("gradle.properties", "build.gradle", "build.gradle.kts"):
        if rel in files:
            m = re.search(r"(?m)^\s*group\s*=?\s*['\"]?([\w.\-]+)['\"]?\s*$", read_rel(repo, rel) or "")
            if m:
                return m.group(1)
    return None


def build_link(repo, svc, hroot):
    """One service → the links/<svc>.json document."""
    loaded = load_plane(repo)
    files = list_repo_files(repo)
    if loaded:
        meta, rows, contracts = loaded
        source, commit = "plane", meta.get("indexed_commit")
    else:
        rows, contracts, files = scan_repo(repo, svc)
        head = git(repo, "rev-parse", "--verify", "-q", "HEAD")
        source, commit = "scan", head.strip() if head else None
    flat = yml_files(repo, files)
    consumes, produces, unres = kafka_sides(repo, rows, contracts, flat)
    props = {"%s:%d" % (rel, e["line"]): e["prop"] for rel in flat for e in flat[rel]}
    dbs = [d for d in contracts.get("db", [])  # a CDC / migration connector URL is not the service's database
           if not DB_SKIP_SEG.intersection(props.get(d.get("at"), "").lower().split("."))]
    has_mig = any(r.get("kind") == "migration" for r in rows)
    comp = [{k: r[k] for k in ("id", "kind", "name", "fqn", "file", "line", "http", "topic", "topic_expr", "table",
                               "target", "purpose", "tags") if r.get(k) not in (None, "", [])} for r in rows]
    remote = re.sub(r"://[^/@]*@", "://", (git(repo, "config", "--get", "remote.origin.url") or "").strip()) or None
    return {"schema": SCHEMA, "svc": svc, "path": os.path.relpath(repo, hroot), "source": source,
            "indexed_commit": commit, "remote": remote, "has_migrations": has_mig, "group": lib_group(repo, files),
            "contracts": dict({k: contracts.get(k, []) for k in ("http_exposed", "http_clients", "client_targets",
                                                                "libs")}, db=dbs),
            "kafka": {"consumes": consumes, "produces": produces}, "unresolved": unres, "components": comp}


# ---------------------------------------------------------------- aliases -------------------------------------
def load_aliases(h):
    a = read_json(os.path.join(h, "aliases.json"), {}) or {}
    return {k: dict(a.get(k) or {}) for k in ALIAS_KEYS}


def aliases_pristine(h):
    """aliases.json may be (re)written by the hub only when absent, an all-empty skeleton, or byte-identical to the
    hub's own last write (sha1 in .aliases.sha1). Any user edit makes it user-owned for good."""
    p = os.path.join(h, "aliases.json")
    try:
        with open(p, encoding="utf-8") as f:
            cur = f.read()
    except OSError:
        return True
    try:
        with open(os.path.join(h, ".aliases.sha1"), encoding="utf-8") as f:
            if f.read().strip() == sha1_text(cur):
                return True
    except OSError:
        pass
    try:
        d = json.loads(cur)
    except ValueError:
        return False
    return isinstance(d, dict) and not any(v for k, v in d.items() if not k.startswith("_") and isinstance(v, dict))


def write_aliases(h, suggested):
    base = {k: {} for k in ALIAS_KEYS}
    doc = dict(base, _suggested=suggested,
               _note="Hub suggestions live in _suggested and are never applied. Copy an entry into env / topic_owner "
                     "/ db_owner / lib_owner to make it win; once you edit this file the hub never rewrites it.")
    if aliases_pristine(h):
        text = dumps(doc)
        write_if_changed(os.path.join(h, "aliases.json"), text)
        write_if_changed(os.path.join(h, ".aliases.sha1"), sha1_text(text) + "\n")
        sp = os.path.join(h, "aliases.suggested.json")
        if os.path.exists(sp):
            os.remove(sp)
    else:
        write_if_changed(os.path.join(h, "aliases.suggested.json"), dumps({"_suggested": suggested}))


# ---------------------------------------------------------------- joins ---------------------------------------
def kebab(env):
    x = re.sub(r"_(SERVICE_URL|SERVICE_URI|BASE_URL|BASE_URI|URL|URI)$", "", env or "")
    x = re.sub(r"_MS$", "", x)
    return x.lower().replace("_", "-")


def host_of(url):
    m = re.match(r"^[a-z][a-z0-9+.-]*://(?:[^@/]*@)?([^:/?#]+)", (url or "").strip(), re.I)
    return m.group(1).lower() if m else ""


def match_name(x, svcs, me=None):
    """x == <name> or <name>-ms → (svc, 'high'); a unique whole-token substring either way (core-ledger in
    pgms-core-ledger, ledger in core-ledger-ms) → (svc, 'medium'). svcs: service keys, or {name: key} where the
    names also carry each repo's dir (payment-gateway-ms for the key pg-ms). The caller's own service never matches."""
    if not x:
        return None, None
    names = svcs if isinstance(svcs, dict) else {s: s for s in svcs}
    names = {n: k for n, k in names.items() if k != me}
    for n in sorted(names):
        if x == n or x + "-ms" == n or x == re.sub(r"-ms$", "", n):
            return names[n], "high"

    def within(a, b):
        return len(a) >= 3 and re.search(r"(^|-)%s(-|$)" % re.escape(a), b) is not None
    cand = {k for n, k in names.items() if within(re.sub(r"-ms$", "", n), x) or within(x, n)}
    if len(cand) == 1:
        return cand.pop(), "medium"
    return None, None


def is_http_client(hc):
    d = hc.get("default_url") or ""
    env = hc.get("env") or ""
    if NON_HTTP_SCHEME.match(d) or NON_HTTP_ENV.search(env):
        return False
    if re.match(r"^https?://", d, re.I):
        return True
    return bool(re.search(r"_(URL|URI)$", env)) and not d


def http_target(hc, svcs, aliases, me=None):
    """→ (target, confidence, reason). target: a service, 'external:<host>', or None (unresolved)."""
    env, host = hc.get("env") or "", host_of(hc.get("default_url"))
    if env and env in aliases["env"]:
        a = aliases["env"][env]
        return (svcs.get(a, a) if isinstance(svcs, dict) else a), "high", "alias"
    if host and host not in LOCAL_HOSTS:
        s, c = match_name(host, svcs, me)
        if c == "high":
            return s, "high", "host"
    s, c = match_name(kebab(env), svcs, me)
    if c == "high":
        return s, c, "env"
    segs = [p for p in (hc.get("prop") or "").split(".")[:-1] if p]
    for seg in reversed(segs):
        seg2 = re.sub(r"-(service|client|api)$", "", seg.lower())
        s2, c2 = match_name(seg2, svcs, me)
        if c2 == "high":
            return s2, "high", "prop"
    if c == "medium":
        return s, "medium", "env-substring"
    if host and host not in LOCAL_HOSTS and "." in host:
        return "external:" + host, "high", "host"
    return None, None, None


def repo_dir(link, svc):
    """The repo's directory name (the services.json path basename): the evidence prefix, and a second name for the
    service when init keyed it by its build name (payment-gateway-ms keyed pg-ms)."""
    return os.path.basename((link.get("path") or svc).rstrip("/")) or svc


def ev_rank(e):
    """application.yml and code first, other profiles next, test/local profiles and src/test last."""
    f = e.rsplit(":", 1)[0]
    b = os.path.basename(f)
    if "/src/test/" in "/" + f or re.search(r"-(test|local)\.ya?ml$", b):
        return 2
    return 1 if re.match(r"application-.+\.ya?ml$", b) else 0


def join(links, aliases):
    svcs = sorted(links)
    edges, unresolved, sugg = {}, [], {k: {} for k in ALIAS_KEYS}
    dirs = {s: repo_dir(links[s], s) for s in svcs}
    names = dict({d: s for s, d in dirs.items()}, **{s: s for s in svcs})  # a key wins over another repo's dir

    def ev(svc, at):
        return "%s/%s" % (dirs.get(svc, svc), at)

    def add(f, t, typ, via, evidence, conf):
        """One edge per (from, to, type, via); http collapses to one edge per (from, to) — every other env that
        reaches the same target goes to also_via (three Keycloak realms are one dependency)."""
        if f == t:
            return
        k = (f, t, typ, None if typ == "http" else via)
        e = edges.get(k)
        if e is None:
            edges[k] = {"from": f, "to": t, "type": typ, "via": via, "evidence": list(dict.fromkeys(evidence)),
                        "confidence": conf}
        else:
            if via != e["via"] and via not in e.get("also_via", []):
                e.setdefault("also_via", []).append(via)
            e["evidence"] = list(dict.fromkeys(e["evidence"] + evidence))
            if CONF_W[conf] > CONF_W[e["confidence"]]:
                e["confidence"] = conf

    # http
    for s in svcs:
        c = links[s]["contracts"]
        entries = [h for h in c.get("http_clients", []) if is_http_client(h)]
        by_at = {h["at"]: h for h in entries}
        for ct in c.get("client_targets", []):  # a client class whose base URL property resolved (ADR-IDX-4)
            h = by_at.get(ct.get("yml_at"))
            if h is not None:
                h.setdefault("_client_at", []).append(ct["at"])
            elif is_http_client(ct):
                entries.append({"env": ct.get("env"), "default_url": ct.get("default_url"), "prop": ct.get("prop"),
                                "at": ct["yml_at"], "_client_at": [ct["at"]]})
        for h in entries:
            t, conf, why = http_target(h, names, aliases, s)
            via = h.get("env") or h.get("prop") or h.get("key")
            evid = [ev(s, h["at"])] + [ev(s, a) for a in h.get("_client_at", [])]
            if t is None:
                u = {"svc": s, "kind": "http_client", "env": h.get("env"), "at": ev(s, h["at"])}
                if host_of(h.get("default_url")) not in LOCAL_HOSTS:
                    u["host"] = host_of(h.get("default_url"))
                unresolved.append(u)
                continue
            if t == s:
                continue
            add(s, t, "http", via, evid, conf)
            if why in ("env-substring",) and h.get("env"):
                sugg["env"][h["env"]] = t
        for r in links[s]["components"]:  # Feign / @HttpExchange name or url naming a service
            if r["kind"] == "client" and r.get("target"):
                tt = r["target"]
                m = re.fullmatch(r"\$\{([A-Z0-9_]+)(?::([^}]*))?\}", tt)
                h = {"env": m.group(1), "default_url": m.group(2)} if m else {"default_url": tt if "://" in tt else "",
                                                                             "env": ""}
                t, conf, _w = http_target(h, names, aliases, s)
                if t is None and not m:
                    t, conf = match_name(tt.lower(), names, s)
                if t and t != s:
                    add(s, t, "http", h.get("env") or tt, [ev(s, "%s:%d" % (r["file"], r["line"]))], conf)
    # kafka
    exact, prefixes = {}, []
    for s in svcs:
        for p in links[s]["kafka"]["produces"]:
            if p.get("topic"):
                exact.setdefault(p["topic"], []).append((s, p))
            elif p.get("prefix"):
                prefixes.append((s, p))
    matched_prefix = set()
    for s in svcs:
        for cns in links[s]["kafka"]["consumes"]:
            t = cns["topic"]
            owner = aliases["topic_owner"].get(t)
            cev = [ev(s, a) for a in cns["at"]]
            if owner:
                add(owner, s, "kafka", t, cev, "high")
                continue
            prods = [(ps, p) for ps, p in exact.get(t, []) if ps != s]
            if prods:
                for ps, p in prods:
                    cf = min(p["conf"], cns.get("conf", "high"), key=lambda c: CONF_W[c])
                    add(ps, s, "kafka", t, [ev(ps, a) for a in p["at"]] + cev, cf)
                continue
            if any(ps == s for ps, _p in exact.get(t, [])):
                continue  # produced and consumed by the same service
            pm = [(ps, p) for ps, p in prefixes if t.startswith(p["prefix"])]
            if pm:
                longest = max(len(p["prefix"]) for _s, p in pm)
                pm = [(ps, p) for ps, p in pm if len(p["prefix"]) == longest]
            if any(ps == s for ps, _p in pm):
                continue  # the service's own outbox prefix
            if len(pm) == 1:
                ps, p = pm[0]
                matched_prefix.add((ps, p["prefix"]))
                add(ps, s, "kafka", t, [ev(ps, a) for a in p["at"]] + cev, "medium")
                sugg["topic_owner"][t] = ps
                continue
            unresolved.append({"svc": s, "kind": "kafka_consume", "topic": t, "at": cev[0]})
    for ps, p in prefixes:
        if (ps, p["prefix"]) not in matched_prefix:
            unresolved.append({"svc": ps, "kind": "kafka_produce", "prefix": p["prefix"], "at": ev(ps, p["at"][0])})
    for s in svcs:
        for u in links[s].get("unresolved", []):
            unresolved.append(dict(u, svc=s, at=ev(s, u["at"])))
    # lib
    owners = {g: names.get(o, o) for g, o in DEFAULT_LIB_OWNER.items()}
    decl = {}
    for s in svcs:
        if links[s].get("group"):
            decl.setdefault(links[s]["group"], []).append(s)
    for g, ss in decl.items():  # a group every service declares (io.f8a) names no owner
        if len(ss) == 1:
            owners[g] = ss[0]
            sugg["lib_owner"][g] = ss[0]
    owners.update({g: names.get(o, o) for g, o in aliases["lib_owner"].items()})
    for s in svcs:
        seen = {}
        for lib in links[s]["contracts"].get("libs", []):
            g = lib["coord"].split(":")[0]
            if g in owners:
                seen.setdefault(g, []).append(ev(s, lib["at"]))
        for g, evid in sorted(seen.items()):
            add(s, owners[g], "lib", g + ":*", evid[:1], "high")
    # db
    users = {}
    for s in svcs:
        for d in links[s]["contracts"].get("db", []):
            e, by = ev(s, d["at"]), users.setdefault(d["name"], {})
            if s not in by or ev_rank(e) < ev_rank(by[s]):
                by[s] = e
    for name, by in sorted(users.items()):
        if len(by) < 2:
            continue
        owner = aliases["db_owner"].get(name)
        if not owner:
            mig = [s for s in by if links[s].get("has_migrations")]
            owner = mig[0] if len(mig) == 1 else None
            if owner:
                sugg["db_owner"][name] = owner
        if owner:
            for s in sorted(by):
                if s != owner:
                    add(s, owner, "db", name, [by[s]] + ([by[owner]] if owner in by else []), "medium")
        else:
            first = sorted(by)[0]
            for s in sorted(by)[1:]:
                add(first, s, "db", name, [by[first], by[s]], "low")
    order = {"http": 0, "kafka": 1, "lib": 2, "db": 3}
    out = sorted(edges.values(), key=lambda e: (order[e["type"]], e["from"], e["to"], e["via"]))
    for e in out:
        e["evidence"] = sorted(e["evidence"], key=ev_rank)[:6]
    unresolved.sort(key=lambda u: (u["svc"], u["kind"], u.get("at") or ""))
    return out, unresolved, {k: dict(sorted(v.items())) for k, v in sugg.items() if v}


# ---------------------------------------------------------------- outputs -------------------------------------
def hub_md(h, services, edges, unresolved):
    hroot = hub_root(h)
    L = ["# Hub — %d services, %d edges" % (len(services), len(edges)),
         "Service paths are relative to the hub root `%s`; evidence is `<repo dir>/<file>:<line>`. Full data: "
         "`.claude/claudehut/hub/service-links.json`; query with `claudehut-index links|svc <name>`."
         % os.path.basename(hroot), "", "## Services"]
    for s in sorted(services):
        m = services[s]
        L.append("- %s `%s` @%s%s" % (s, m.get("path"), (m.get("indexed_commit") or "none")[:7],
                                     "" if m.get("has_plane") else " (hub-scan)"))
    L += ["", "## Edges (from → to · type · via · confidence)"]
    rest = []
    for e in edges:
        rest.append("- %s → %s · %s · %s · %s" % (e["from"], e["to"], e["type"], e["via"], e["confidence"]))
    tail = ["", "Unresolved: %d (see service-links.json `unresolved`, fix with aliases.json)." % len(unresolved)]
    text = "\n".join(L)
    used = len((text + "\n").encode("utf-8")) + len(("\n".join(tail) + "\n").encode("utf-8")) + 60
    kept = 0
    for ln in rest:
        n = len((ln + "\n").encode("utf-8"))
        if used + n > HUB_MD_MAX:
            break
        text += "\n" + ln
        used += n
        kept += 1
    if kept < len(rest):
        text += "\n- … +%d more (claudehut-index links)" % (len(rest) - kept)
    text += "\n" + "\n".join(tail)
    return clip(text, HUB_MD_MAX - 1) + "\n"


def graph(h, services, links, edges, analyzed_at):
    """Service-level knowledge graph in UA's schema (understand-anything core/src/schema.ts KnowledgeGraphSchema):
    every node carries id/type/name/summary/tags/complexity, every edge source/target/type/direction/weight, so
    UA's sanitizeGraph/autoFixGraph change nothing and validateGraph reports 0 issues."""
    nodes, gedges = {}, []

    def node(nid, typ, name, summary, tags):
        if nid not in nodes:
            nodes[nid] = {"id": nid, "type": typ, "name": name, "summary": summary, "tags": tags, "complexity": "simple"}
        return nid

    def svc_node(s):
        if s in links:
            c = links[s]["contracts"]
            summ = "%s: %d endpoints, consumes %d topic(s), produces %d; %s" % (
                s, len(c.get("http_exposed", [])), len(links[s]["kafka"]["consumes"]),
                len(links[s]["kafka"]["produces"]), "indexed plane" if links[s]["source"] == "plane" else "hub-scan")
            n = len(links[s]["components"])
            nd = node("service:" + s, "service", s, summ, ["service"])
            nodes[nd]["complexity"] = "complex" if n > 300 else "moderate" if n > 80 else "simple"
            return nd
        return node("service:" + s, "service", s, "%s (not registered in the hub)" % s, ["service", "external"])

    for s in sorted(services):
        svc_node(s)

    def gedge(a, b, typ, conf):
        gedges.append({"source": a, "target": b, "type": typ, "direction": "forward", "weight": CONF_W[conf],
                       "description": ""})

    for e in edges:
        a = svc_node(e["from"])
        if e["type"] == "http":
            if e["to"].startswith("external:"):
                host = e["to"].split(":", 1)[1]
                b = node("resource:external:" + host, "resource", host, "External HTTP host %s" % host, ["external"])
            else:
                b = svc_node(e["to"])
            gedge(a, b, "calls", e["confidence"])
            gedges[-1]["description"] = "HTTP via %s" % e["via"]
        elif e["type"] == "kafka":
            tp = node("topic:" + e["via"], "topic", e["via"], "Kafka topic %s" % e["via"], ["kafka"])
            gedge(a, tp, "publishes", e["confidence"])
            gedges[-1]["description"] = "publishes %s" % e["via"]
            gedge(svc_node(e["to"]), tp, "subscribes", e["confidence"])
            gedges[-1]["description"] = "subscribes %s" % e["via"]
        elif e["type"] == "lib":
            g = e["via"].split(":")[0]
            short = g.split(".")[-1]
            m = node("module:" + short, "module", g, "Shared library group %s (owner %s)" % (g, e["to"]), ["lib"])
            gedge(a, m, "depends_on", e["confidence"])
            gedges[-1]["description"] = "uses %s" % e["via"]
        elif e["type"] == "db":
            t = node("table:" + e["via"], "table", e["via"], "Database %s shared by services" % e["via"], ["db"])
            for s in (e["from"], e["to"]):
                gedge(svc_node(s), t, "reads_from", e["confidence"])
                gedges[-1]["description"] = "uses database %s" % e["via"]
    uniq = {}
    for g in gedges:
        k = (g["source"], g["target"], g["type"])
        if k not in uniq or g["weight"] > uniq[k]["weight"]:
            uniq[k] = g
    gedges = sorted(uniq.values(), key=lambda g: (g["source"], g["target"], g["type"]))
    layers = []
    for lid, name, typ, desc in (("layer:services", "Services", "service", "Registered and referenced services"),
                                 ("layer:topics", "Kafka topics", "topic", "Topics joining producers and consumers"),
                                 ("layer:data", "Databases", "table", "Databases used by more than one service"),
                                 ("layer:libs", "Shared libraries", "module", "Shared library groups"),
                                 ("layer:external", "External", "resource", "External HTTP hosts")):
        ids = sorted(n for n, v in nodes.items() if v["type"] == typ)
        if ids:
            layers.append({"id": lid, "name": name, "description": desc, "nodeIds": ids})
    name = os.path.basename(hub_root(h))
    return {"version": "1.0.0", "kind": "codebase",
            "project": {"name": name, "languages": ["java"], "frameworks": ["spring-boot"],
                        "description": "Service-level graph of %d services generated by claudehut-index hub-sync "
                                       "(07-index-memory.md §4.3)" % len(services),
                        "analyzedAt": analyzed_at, "gitCommitHash": "multi"},
            "nodes": [nodes[k] for k in sorted(nodes)], "edges": gedges, "layers": layers, "tour": []}


def commit_date(repo, sha):
    if not sha:
        return None
    d = git(repo, "show", "-s", "--format=%cI", sha)
    return d.strip() if d else None


# ---------------------------------------------------------------- sync ----------------------------------------
def ensure_hub(h):
    os.makedirs(h, exist_ok=True)
    if not os.path.exists(os.path.join(h, "hub.json")):
        write_atomic(os.path.join(h, "hub.json"), json.dumps({"schema": SCHEMA}, indent=2) + "\n")
    gi = os.path.join(h, ".gitignore")  # 07 §8.3: links/, service-links.json, .understand-anything/ are not committed
    try:
        with open(gi, encoding="utf-8") as f:
            have = f.read()
    except OSError:
        have = ""
    miss = [x for x in GITIGNORE if x not in have.splitlines()]
    if miss:
        write_atomic(gi, have + ("" if not have or have.endswith("\n") else "\n") + "\n".join(miss) + "\n")


def sync(h, add_repos=()):
    """Register add_repos, then rebuild every output from all registered services: a repo with a built plane is read
    from its index, any other is hub-scanned read-only (hub-scan and hub-sync differ only in intent). Returns a
    summary dict."""
    t0 = time.time()
    ensure_hub(h)
    hroot = hub_root(h)
    with Lock(h) as lk:
        if not lk.ok:
            return {"synced": False, "reason": "locked"}
        raw = read_json(os.path.join(h, "services.json"), {}) or {}
        other = {k: v for k, v in raw.items() if not isinstance(v, dict)}  # carried through untouched
        services = {k: v for k, v in raw.items() if isinstance(v, dict)}
        for r in add_repos:
            repo = repo_top(os.path.abspath(r))
            s = svc_name(repo)
            ent = dict(services.get(s) or {})
            ent["path"] = os.path.relpath(repo, hroot)
            services[s] = ent
        links, missing = {}, []
        for s in sorted(services):
            repo = os.path.normpath(os.path.join(hroot, services[s].get("path") or s))
            if not os.path.isdir(repo):
                missing.append(s)
                continue
            lk_doc = build_link(repo, s, hroot)
            links[s] = lk_doc
            changed = write_if_changed(os.path.join(h, "links", s + ".json"), dumps(lk_doc))
            ent = services[s]
            if changed or ent.get("indexed_commit") != lk_doc["indexed_commit"] or not ent.get("synced_at"):
                ent["synced_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())  # only when the view moved,
            ent.update(path=lk_doc["path"], indexed_commit=lk_doc["indexed_commit"],  # so a committed services.json
                       has_plane=lk_doc["source"] == "plane")                          # stays clean on no-op syncs
            if lk_doc["remote"]:
                ent["remote"] = lk_doc["remote"]
            else:
                ent.setdefault("remote", None)
        aliases = load_aliases(h)
        edges, unresolved, sugg = join(links, aliases)
        write_aliases(h, sugg)
        write_if_changed(os.path.join(h, "services.json"), dumps(dict(other, **services)))
        write_if_changed(os.path.join(h, "service-links.json"),
                         dumps({"schema": SCHEMA, "edges": edges, "unresolved": unresolved}))
        write_if_changed(os.path.join(h, "HUB.md"), hub_md(h, {k: services[k] for k in links}, edges, unresolved))
        dates = [d for d in (commit_date(os.path.join(hroot, services[s]["path"]), services[s].get("indexed_commit"))
                             for s in links) if d]
        analyzed = max(dates) if dates else "1970-01-01T00:00:00Z"
        g = graph(h, {k: services[k] for k in links}, links, edges, analyzed)
        ua = os.path.join(h, ".understand-anything")
        write_if_changed(os.path.join(ua, "knowledge-graph.json"), json.dumps(g, ensure_ascii=False, indent=1) + "\n")
        write_if_changed(os.path.join(ua, "meta.json"), json.dumps(
            {"lastAnalyzedAt": analyzed, "gitCommitHash": "multi", "version": "1.0.0",
             "analyzedFiles": len(links)}, indent=1) + "\n")
    counts = {}
    for e in edges:
        counts[e["type"]] = counts.get(e["type"], 0) + 1
    return {"synced": True, "hub": h, "services": len(links), "missing": missing, "edges": len(edges),
            "by_type": counts, "unresolved": len(unresolved), "elapsed_ms": int((time.time() - t0) * 1000)}


def summary_line(r):
    if not r.get("synced"):
        return "hub: sync skipped — %s" % r.get("reason")
    bt = ", ".join("%s %d" % (k, r["by_type"].get(k, 0)) for k in ("http", "kafka", "lib", "db"))
    miss = " · missing: %s" % ", ".join(r["missing"]) if r["missing"] else ""
    return "hub: synced %d services, %d edges (%s), %d unresolved (%d ms) → %s%s" % (
        r["services"], r["edges"], bt, r["unresolved"], r["elapsed_ms"], r["hub"], miss)


# ---------------------------------------------------------------- read side (CLI) -----------------------------
def read_links(h):
    return read_json(os.path.join(h, "service-links.json"), {}) or {}


def read_link(h, svc):
    return read_json(os.path.join(h, "links", svc + ".json"))


def services_of(h):
    return read_json(os.path.join(h, "services.json"), {}) or {}


def resolve_svc(h, name):
    """A service key, or its repo dir name (auth-ms for the key auth-service) → the key; unknown names pass through."""
    svcs = services_of(h) if h else {}
    if not name or name in svcs:
        return name
    hits = [k for k, v in svcs.items() if isinstance(v, dict) and repo_dir(v, k) == name]
    return hits[0] if len(hits) == 1 else name


def behind(h, svc):
    """Commits the hub's view of svc lags its repo HEAD (None when unknown). Read-only."""
    ent = services_of(h).get(svc) or {}
    repo = os.path.normpath(os.path.join(hub_root(h), ent.get("path") or svc))
    ic = ent.get("indexed_commit")
    head = git(repo, "rev-parse", "--verify", "-q", "HEAD")
    head = head.strip() if head else None
    if not ic or not head:
        return None, repo, ent
    if ic == head:
        return 0, repo, ent
    n = git(repo, "rev-list", "--count", "%s..%s" % (ic, head))
    return (int(n.strip()) if n else None), repo, ent


def render_svc(link, edges, stale_note, repo, budget=2499):
    """repo: the service's absolute root — every path below is relative to it (printed once in the header)."""
    s = link["svc"]
    c = link["contracts"]
    by = {}
    for r in link["components"]:
        by.setdefault(r["kind"], []).append(r)
    L = ["# %s (hub · %s@%s)%s" % (s, link["source"], (link.get("indexed_commit") or "none")[:7], stale_note),
         "repo: %s (paths below are relative to it)" % repo]
    eps = c.get("http_exposed", [])
    if eps:
        L.append("Endpoints (%d):" % len(eps))
        L += ["- %s %s %s" % (e["method"], e["path"], e["at"]) for e in eps[:12]]
        if len(eps) > 12:
            L.append("- … +%d (find --svc %s --kind endpoint)" % (len(eps) - 12, s))
    subs = sorted({x["topic"] for x in link["kafka"]["consumes"]})
    pubs = sorted({x.get("topic") or (x.get("prefix", "") + "*") for x in link["kafka"]["produces"]})
    if subs or pubs:
        L.append("Kafka: consumes %s; produces %s" % (", ".join(subs) or "-", ", ".join(pubs) or "-"))
    out_e = [e for e in edges if e["from"] == s]
    in_e = [e for e in edges if e["to"] == s]
    def peers(es, side):
        seen = {}
        for e in es:
            k = (e[side], e["type"])
            if k not in seen or CONF_W[e["confidence"]] > CONF_W[seen[k]]:
                seen[k] = e["confidence"]
        return ", ".join("%s(%s %s)" % (p, t, c) for (p, t), c in list(seen.items())[:14])
    if out_e:
        L.append("Calls/uses: " + peers(out_e, "to"))
    if in_e:
        L.append("Used by: " + peers(in_e, "from"))
    cl = [r for r in by.get("client", [])]
    if cl:
        L.append("Clients: " + ", ".join(r["name"] for r in cl[:10]))
    dbs = sorted({d["name"] for d in c.get("db", [])})
    if dbs:
        L.append("DB: " + ", ".join(dbs))
    tabs = sorted({r["table"] for r in by.get("entity", []) + by.get("migration", []) if r.get("table")})
    if tabs:
        L.append("Tables: " + ", ".join(tabs[:16]))
    svcs = by.get("service", [])
    if svcs:
        L.append("Services: " + ", ".join(r["name"] for r in svcs[:16]))
    return clip("\n".join(L), budget)
