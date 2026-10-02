"""hub.py — the microservice hub of claudehut-index (07-index-memory.md §4.3, AC-8..AC-10; ADR-IDX-3/4).

python3 stdlib only. The hub aggregates per-service contracts into cross-service edges with evidence. It reads
service repos and never writes into them (no .claude/, no .understand-anything/, no git lock: every git call runs
with GIT_OPTIONAL_LOCKS=0).

Layout (<HUB> is the hub root, e.g. <workspace>/ewallet-knowledge; H = <HUB>/.claude/claudehut/hub):
  H/hub.json              {schema:1, language?}      init writes language; the hub only creates {schema:1}
  H/services.json         {"<svc>": {path, remote, indexed_commit, synced_at, has_plane}}  path relative to <HUB>
  H/aliases.json          {env:{}, topic_owner:{}, db_owner:{}, lib_owner:{}, ignore:{}, manifests?, _suggested:{…}}
                          user-owned; an env value may be external:<host>; manifests = deploy-manifest dir(s) from <HUB>;
                          ignore = {"<ENV>|<topic>|<svc>:<ENV|topic>": reason} — a user decision (dead config, retired
                          topic): a matching client / consumer / producer row → ignored "declared in aliases.json: …"
  H/links/<svc>.json      per-service contracts (+ resolved kafka topics, compact components) — plane or hub-scan
  H/service-links.json    {schema:1, edges:[…], unresolved:[…], ignored:[…+reason], dynamic:[…+reason]}  no timestamps
  H/HUB.md                ≤3 KB, paths from <HUB>
  H/.understand-anything/knowledge-graph.json + meta.json   service-level graph in UA schema (GRAPH_DIR = H)

Join rules (07 §4.3 table):
  http   client env / resolved client property → service: aliases.env wins (high); default-URL host == service
         (high); env stripped of _SERVICE_URL|_BASE_URL|_URL|_URI and _MS, kebab == <x>|<x>-ms (high); a property
         key segment == <x>|<x>-ms (high); a unique substring match (medium); a dotted host → external:<host>;
         else unresolved. Only entries with an http(s) default or an env ending _URL/_URI count as HTTP clients.
         Before those: a test/local-profile entry → ignored (never an edge); a deploy-manifest value of the env
         (aliases.manifests) → the service it names (image / applicationName, <name>.<namespace>), a deployed app
         the hub lacks → external:<app>, a public host → external:<host>; but first, a key whose every src/main use
         is UI model data (put/Map.of with a literal key, a Mail/Notification/Template argument) and none an HTTP
         client (baseUrl/uri/WebClient/RestTemplate/RestClient/HttpClient/Feign) → ignored "UI link" (by use). After
         them: a key no src/main code reads → ignored (dead config); a portal/login/deeplink key with no HTTP-client
         use → ignored; an address naming the service itself → ignored (self). Another service's datasource URL
         (…datasources.<x>.url) → a db edge to the owner of its deployed schema (aliases.db_owner wins).
  kafka  consumer topics come from @KafkaListener (literal, ${prop:default}, same-file constant, SpEL
         #{'${prop:default}'.split(',')}) resolved against application*.yml; producer topics from KafkaTemplate
         literals / @Value fields (high), from yml topic keys not under a consumer path and not consumed by the same
         service (medium), and outbox topic-prefix (prefix match, medium). Exact == high unless the producer side is
         a yml heuristic; no producer → unresolved. Source scan adds handler consumers (getSupportedTopics() /
         topic() → props getter / @Value) and publisher route tables / outbox saveEvent topics. A manifest ENV
         value wins over ${ENV:default}. DLT/replay, outbox and wrapper (topic parameter) send sites → dynamic; an
         empty unset topic property → ignored; a prefix no other service consumes → dynamic, and so does a prefix the
         publisher bypasses (its topics are routed explicitly; "superseded"); a prefix-composed saveEvent topic cites
         the prefix line. A self-produced (or own-prefix) consumed topic and a static topic no registered consumer
         names → ignored. aliases.ignore (unscoped or <svc>:) beats every rule but the test/local profile. Every input row ends in an edge or exactly one bucket row (hub-tests `account`).
  lib    one edge per (service, library module): a dependency whose group a registered library publishes (a repo
         extract.library_info detects as a multi-module publisher), or aliases.lib_owner / a gradle `group=` only one
         service declares / io.f8a.summer → owner, high. The edge carries module, version and version_src (explicit,
         property, catalog, or bom = the version of the service's platform/BOM of that group; bom_version always).
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
NON_HTTP_ENV = re.compile(r"(^|_)(R2DBC|FLYWAY|DATASOURCES?|JDBC|REDIS|KAFKA|RABBITMQ|MONGODB?|LIQUIBASE)(_|$)")
DATASOURCE_RE = re.compile(r"(^|[._])datasources?([._]|$)", re.I)
OWN_DS_ENV = re.compile(r"^SPRING_(R2DBC|DATASOURCE|FLYWAY|LIQUIBASE)_URL$")
UI_LINK_RE = re.compile(r"(?i)(portal|login[-_.]?url|deep[-_.]?link|redirect[-_.]?ur[il]|frontend|web[-_.]?url)")
FRAMEWORK_PROP = ("spring.", "management.", "server.", "logging.", "springdoc.", "resilience4j.", "eureka.", "otel.")
SECRET_KEY = re.compile(r"(?i)(passw|secret|token|jaas|credential|private[-_]?key|api[-_]?key)")
MANIFEST_SKIP = re.compile(r"(?i)(^|/)(secrets?[^/]*|[^/]*\.enc\.ya?ml|\.?sops[^/]*)$")
HELM_ENV_RE = re.compile(r"(?:^|\.)env\.([A-Za-z_][A-Za-z0-9_]*)\.value$")
K8S_ENV_RE = re.compile(r"^[ \t]*-[ \t]*name:[ \t]*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?[ \t]*\n[ \t]*value:[ \t]*['\"]?([^'\"\n#]*)", re.M)
TOPIC_RE = re.compile(r"[A-Za-z0-9_.\-]+")
NON_HTTP_SCHEME = re.compile(r"^(r2dbc|jdbc|redis|rediss|mongodb|amqp|amqps|kafka|tcp|file|classpath):", re.I)
TOPIC_SKIP_LEAF = {"offset-storage-topic", "schema-history-topic", "topic-prefix"}
ALIAS_KEYS = ("env", "topic_owner", "db_owner", "lib_owner", "ignore")
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
    lib = extract.library_info(files, lambda rel: read_rel(repo, rel))
    rows, texts = extract.library_rows(lib, svc), {}
    for p in files:
        if extract.is_source(p):
            t = read_rel(repo, p)
            if t is not None:
                try:
                    rows.extend(extract.extract_file(p, t, svc, lib))
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


def yml_val(value, over=None):
    """A yml scalar → its effective value: ${ENV:default} → the deploy manifest's ENV value when one is set (over),
    else the default; a plain scalar is itself."""
    inner = extract.YML_REF_RE.search(value or "")
    if inner and over and inner.group(1) in over:
        return ",".join(over[inner.group(1)])
    return (inner.group(2) if inner else value) or ""


def placeholder_values(expr, flat, over=None):
    """'${a.b:x,y}' / "#{'${a.b:x}'.split(',')}" / a literal → ([topics], yml_at|None). Placeholders resolve against
    application*.yml (whose value may itself be ${ENV:default}; a deploy-manifest ENV value wins over that default);
    the in-code default is the fallback."""
    refs = extract.YML_REF_RE.findall(expr or "")
    if not refs:
        lit = (expr or "").strip()
        if not lit or lit.startswith("#{") or not re.fullmatch(r"[A-Za-z0-9_.,\- ]+", lit):
            return [], None
        return [t.strip() for t in lit.split(",") if t.strip()], None
    vals, at = [], None
    for prop, dflt in refs:
        val = None
        if prop.isupper() and over and prop in over:
            val = ",".join(over[prop])
        elif not prop.isupper():
            rel, e = extract.yml_lookup(flat, prop)
            if e:
                val = yml_val(e["value"], over) or None
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


def field_expr(text, ident):
    """topic_expr `ident` → the @Value("${…}") or constant expression that defines it in `text` (one source file)."""
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


def value_field_expr(repo, rel, ident):
    """topic_expr `ident` of a producer → the @Value("${…}") or constant expression that defines it (same file)."""
    return field_expr(read_rel(repo, rel), ident)


# ---------------------------------------------------------------- source scan (read-only) ---------------------
# Planes are frozen per service (components.jsonl), so every rule below reads the repo's src/main sources here.
PROPS_CLASS_RE = re.compile(r'@ConfigurationProperties\s*\(\s*(?:(?:prefix|value)\s*=\s*)?"([^"]+)"[^)]*\)\s*'
                            r'(?:@\w+(?:\([^)]*\))?\s*)*(?:(?:public|final|abstract|open|data)\s+)*(?:class|record)\s+(\w+)')
CLASS_RE = re.compile(r"\b(?:class|record|object)\s+(\w+)([^{;]*)\{")
FIELD_RE = re.compile(r"\b([A-Z]\w*)(?:<[^;=(){}]*>)?\s+(\w+)\s*[;=),]")
GETTER_CALL_RE = re.compile(r"\b([a-z]\w*)\s*\.\s*(get\w*Topics?)\s*\(\s*\)")
TOPIC_METHOD_RE = re.compile(r"\b(getSupportedTopics|supportedTopics|getTopics|topics|getTopic|topic)\s*\(\s*\)"
                             r"\s*(?::\s*[\w<>?, ]+)?\s*\{")


def code_index(repo, files):
    """src/main Java/Kotlin texts + what binds config: @ConfigurationProperties classes {Class: (prefix, rel)}, the
    relaxed ${…} keys and string literals the code names, and the relaxed identifiers of config-shaped files."""
    texts = {}
    for p in files:
        if p.endswith((".java", ".kt")) and "src/main/" in p and not extract.excluded(p):
            t = read_rel(repo, p)
            if t is not None:
                texts[p] = t
    props, lits, refs, idents = {}, set(), set(), set()
    for rel, t in texts.items():
        found = PROPS_CLASS_RE.findall(t)
        for pre, cls in found:
            props[cls] = (pre, rel)
        if found or re.search(r"(Properties|Props|Config|Settings)\.(java|kt)$", rel):
            idents.update(extract.relax(x) for x in re.findall(r"\b[a-z]\w*", t))
        for s in re.findall(r'"([^"\\\n]{1,200})"', t):
            lits.add(extract.relax(s))
            refs.update(extract.relax(p) for p, _d in extract.YML_REF_RE.findall(s))
    return {"texts": texts, "props": props, "lits": lits, "refs": refs, "idents": idents}


def prop_bound(prop, code):
    """False only when nothing in src/main can read `prop`: no ${prop} in code, no string literal naming its owning
    segment (a map-style registry looks the entry up by that name), no config class field of that name. Framework
    namespaces (spring., management., …) are bound by Spring itself."""
    if not prop or not code or prop.startswith(FRAMEWORK_PROP):
        return True
    segs = prop.split(".")
    if len(segs) < 2 or extract.relax(prop) in code["refs"]:
        return True
    seg = extract.relax(segs[-2])
    return seg in code["lits"] or seg in code["idents"]


HTTP_CALLEE = {"baseUrl", "rootUri", "uri", "uriTemplateHandler", "target", "newBuilder"}
HTTP_TYPE_RE = re.compile(r"(?i)(WebClient|RestTemplate|RestClient|HttpClient|HttpRequest|Feign)")
UI_TYPE_RE = re.compile(r"(?i)(mail|notif|template|sms|push)")
MODEL_PUT = {"put", "putIfAbsent", "of", "entry", "setVariable", "addAttribute", "with", "data"}
NEUTRAL_CALLEE = {"isBlank", "isEmpty", "hasText", "hasLength", "isNotBlank", "isNotEmpty", "requireNonNull",
                  "trace", "debug", "info", "warn", "error", "if", "while"}


def use_kind(src, a, b):
    """The value read at src.code[a:b] → 'http' (it reaches an HTTP client builder: baseUrl/uri/rootUri/target,
    WebClient/RestTemplate/RestClient/HttpClient/Feign), 'ui' (a keyed model entry — put/Map.of/setVariable with a
    literal key — or an argument of a Mail/Notification/Template/Sms/Push type), 'neutral' (a null/blank check,
    a log line) or None (anything else: passed on, assigned, returned)."""
    code, skel = src.code, src.skel
    after = code[b:b + 40]
    if re.match(r"\s*(?:[!=]=\s*null|\.\s*(?:isBlank|isEmpty|equals|length)\s*\()", after) \
            or re.search(r"null\s*[!=]=\s*$", code[max(0, a - 12):a]):
        return "neutral"
    callees, i, depth, comma, first = [], a - 1, 0, None, True
    while i >= 0 and len(callees) < 6:
        ch = skel[i]
        if ch in ")]}":
            depth += 1
        elif ch in "([{" and depth:
            depth -= 1
        elif ch == "," and not depth and comma is None and first:
            comma = i
        elif ch == "(" and not depth:
            m = re.search(r"(new\s+)?([\w.]*?)(\w+)\s*(?:<[^<>()]*>)?\s*$", code[max(0, i - 120):i])
            name, qual = (m.group(3), m.group(2)) if m else ("", "")
            prev = None
            if first and comma is not None:
                prev = extract.split_top(code[i + 1:comma])
                prev = prev[-1].strip() if prev else None
            callees.append((name, qual, prev))
            first = False
        elif ch in ";{}" and not depth:
            break
        i -= 1
    for name, qual, _p in callees:
        if name in HTTP_CALLEE or HTTP_TYPE_RE.search(name) or HTTP_TYPE_RE.search(qual) \
                or (name in ("create", "url") and re.search(r"(?i)(WebClient|URI|Feign|RestClient)\.$", qual)):
            return "http"
    if not callees:
        return None
    name, _q, prev = callees[0]
    if (name in MODEL_PUT and prev and re.fullmatch(r'"[^"]*"', prev)) or any(UI_TYPE_RE.search(n) for n, _q, _p in callees):
        return "ui"
    return "neutral" if name in NEUTRAL_CALLEE else None


def prop_use(prop, code):
    """How src/main reads `prop`: its @Value fields (their uses in the declaring file) and the getter chain of its
    @ConfigurationProperties class (app.merchant-portal.url → .getMerchantPortal().getUrl(), any file) →
    ('http'|'ui'|None, [rel:line of the ui uses]). 'ui' = every use is UI model data (or a null check / log) and at
    least one is; any HTTP-client use wins; no use found → None (the key-name rules decide)."""
    if not prop or not code or prop.startswith(FRAMEWORK_PROP):
        return None, []
    want, sites = extract.relax(prop), []
    low = code.setdefault("relaxed", {})
    for rel, t in sorted(code["texts"].items()):
        if rel not in low:
            low[rel] = extract.relax(t)
        if want.split(".")[-1] not in low[rel]:
            continue
        src = None
        for m in re.finditer(r'@Value\s*\(\s*"\$\{([^:}]+)[^"]*"\s*\)\s*(?:(?:private|protected|public|final)\s+)*'
                             r'[\w.<>]+\s+(\w+)\s*[;=]', t):
            if extract.relax(m.group(1)) != want:
                continue
            src = src or extract.Src(t)
            for u in re.finditer(r"\b%s\b" % re.escape(m.group(2)), src.code):
                if not m.start() <= u.start() < m.end():
                    sites.append((rel, src, u.start(), u.end()))
        for cls, (pre, _r) in code["props"].items():
            if not want.startswith(extract.relax(pre) + "."):
                continue
            segs = prop.split(".")[len(pre.split(".")):]
            pat = r"\s*".join([r"\.\s*get(\w+)\s*\(\s*\)"] * len(segs))
            src = src or extract.Src(t)
            for u in re.finditer(pat, src.code):
                if [extract.relax(g) for g in u.groups()] == [extract.relax(x) for x in segs]:
                    a = u.start()
                    while a and (src.code[a - 1].isalnum() or src.code[a - 1] in "_."):
                        a -= 1  # the receiver: props.getMerchantPortal().getUrl()
                    sites.append((rel, src, a, u.end()))
    kinds = [(use_kind(src, a, b), "%s:%d" % (rel, src.line(a))) for rel, src, a, b in sites]
    if any(k == "http" for k, _a in kinds):
        return "http", []
    ui = [at for k, at in kinds if k == "ui"]
    if ui and all(k in ("ui", "neutral") for k, _a in kinds):
        return "ui", list(dict.fromkeys(ui))
    return None, []


def body_at(t, i):
    """t[i] == '{' (or '(') → (inner text, index of the matching close)."""
    o = t[i]
    c = "}" if o == "{" else ")"
    depth = 0
    for j in range(i, len(t)):
        if t[j] == o:
            depth += 1
        elif t[j] == c:
            depth -= 1
            if depth == 0:
                return t[i + 1:j], j
    return t[i + 1:], len(t)


def getter_entry(code, cls, getter, flat):
    """props.get<X>Topic() on a @ConfigurationProperties class → (yml rel, entry) of the key it reads: the constant
    passed to its map lookup (getTopic(TOPIC_X_KEY) → <prefix>.….<key>), the field it returns, or the getter name
    itself (Lombok). Test/local profiles are never the source."""
    pre, rel = code["props"][cls]
    t = code["texts"].get(rel, "")
    cands = []
    m = re.search(r"\b%s\s*\(\s*\)\s*(?::\s*\w+\s*)?\{([^{}]*)\}" % re.escape(getter), t)
    if m:
        consts = dict(extract.CONST_RE.findall(t))
        c = re.search(r"\(\s*(?:\w+\.)?([A-Z][A-Z0-9_]*)\s*[,)]", m.group(1))
        if c and c.group(1) in consts:
            cands.append(consts[c.group(1)])
        r = re.search(r"return\s+(?:this\.)?([a-z]\w*)\s*;", m.group(1))
        if r:
            cands.append(r.group(1))
    else:
        x = getter[3:]
        cands += [x, re.sub(r"Topics?$", "", x)]
    rp = extract.relax(pre) + "."
    for want in [extract.relax(c) for c in cands if c]:
        for frel in sorted((r for r in flat if ev_rank(r) < 2), key=lambda r: (ev_rank(r), r)):
            for e in flat[frel]:
                q = extract.relax(e["prop"])
                if q.startswith(rp) and (q == rp + want or q.endswith("." + want)):
                    return frel, e
    return None, None


def code_kafka(code, flat, over, prefixes):
    """Source-level Kafka sides the component rows miss → (consumes, produces):
    consume  a handler class (name/supertype Handler|Consumer|Listener|Subscriber) whose getSupportedTopics()/topic()
             returns props.get<X>Topic(), an @Value field or a literal (summer AbstractKafkaMessageHandler & co.)
    produce  props.get<X>Topic() in a publisher class (Publisher|Producer|Sender|Outbox — a custom outbox publisher's
             route table); outbox saveEvent(id, type, payload, topic) → topic (high); saveEvent(id, "x", payload)
             with a topic-prefix → prefix + "x" (medium, via_prefix: the prefix line is its evidence too). DLT
             classes never count. prefixes: {prefix: yml rel:line}."""
    cons, prods = [], []
    if not code:
        return cons, prods
    for rel, t in sorted(code["texts"].items()):
        cm = CLASS_RE.search(t)
        if not cm:
            continue
        cname, ext = cm.group(1), cm.group(2)
        if re.search(r"Dlt|DeadLetter", cname):
            continue
        fields = {n: ty for ty, n in FIELD_RE.findall(t)}

        def line(pos):
            return t.count("\n", 0, pos) + 1

        def topics_of(expr):
            expr = (expr or "").strip()
            lit = re.fullmatch(r'"([^"]*)"', expr)
            if lit:
                return [lit.group(1)] if TOPIC_RE.fullmatch(lit.group(1)) else [], None
            g = GETTER_CALL_RE.fullmatch(expr)
            if g:
                cls = fields.get(g.group(1))
                if cls in code["props"]:
                    frel, e = getter_entry(code, cls, g.group(2), flat)
                    if e:
                        return [v.strip() for v in yml_val(e["value"], over).split(",")
                                if TOPIC_RE.fullmatch(v.strip())], "%s:%d" % (frel, e["line"])
                return [], None
            if re.fullmatch(r"(?:this\.)?\w+", expr):
                fe = field_expr(t, expr.replace("this.", ""))
                if fe:
                    return placeholder_values(fe, flat, over)
            return [], None

        spans = []
        if re.search(r"Handler|Consumer|Listener|Subscriber", cname + ext):
            for m in TOPIC_METHOD_RE.finditer(t):
                body, end = body_at(t, m.end() - 1)
                spans.append((m.start(), end))
                exprs = [g.group(0) for g in GETTER_CALL_RE.finditer(body)]
                exprs += re.findall(r"return\s+((?:this\.)?\w+)\s*;", body) + re.findall(r'"[^"]*"', body)
                for x in exprs:
                    ts, yat = topics_of(x)
                    for tp in ts:
                        cons.append({"topic": tp, "at": [a for a in ("%s:%d" % (rel, line(m.start())), yat) if a]})
        if re.search(r"Publisher|Producer|Sender|Outbox", cname + ext):
            for g in GETTER_CALL_RE.finditer(t):
                if any(a <= g.start() <= b for a, b in spans):
                    continue
                ts, yat = topics_of(g.group(0))
                for tp in ts:
                    prods.append({"topic": tp, "at": [a for a in ("%s:%d" % (rel, line(g.start())), yat) if a],
                                  "conf": "high"})
        for m in re.finditer(r"\.\s*saveEvent\s*\(", t):
            args = extract.split_top(body_at(t, m.end() - 1)[0])
            at = "%s:%d" % (rel, line(m.start()))
            if len(args) >= 4:
                ts, yat = topics_of(args[3])
                prods += [{"topic": tp, "at": [a for a in (at, yat) if a], "conf": "high"} for tp in ts]
            elif len(args) == 3:
                ts, _y = topics_of(args[1])
                prods += [{"topic": p + tp, "at": [at, pat], "conf": "medium", "via_prefix": p}
                          for tp in ts for p, pat in sorted(prefixes.items())]
    return cons, prods


def producer_bucket(text, rel, fe, ts):
    """An unresolved producer send site → (bucket, reason) when the hub can say why its topic is not static."""
    text = text or ""
    if re.search(r"(?i)dlt|dead.?letter|replay", rel) or re.search(r'DltPublishContract|DeadLetterPublishingRecoverer|"\.dlt"', text):
        return "dynamic", "dead-letter/replay publisher: the topic comes from the failed record (<topic>.dlt or its origin)"
    if re.search(r"implements\s+[\w.<>, ]*OutboxEventPublisher|class\s+\w*Outbox\w*Publisher", text):
        return "dynamic", "outbox publisher: topic = the event's explicit topic, else topic-prefix + eventType"
    if re.search(r"\(\s*[^()]*\bString\s+\w*[tT]opic\w*\s*[,)]", text):
        return "dynamic", "producer wrapper: the topic is a method parameter; its callers name the topics"
    refs = extract.YML_REF_RE.findall(fe or "")
    if refs and not ts and all(not d for _p, d in refs):
        return "ignored", "topic property %s is empty by default and set in no yml or manifest (publish disabled)" % refs[0][0]
    return None, None


def kafka_sides(repo, rows, contracts, flat, code=None, over=None):
    """→ (consumes[{topic, at[], src}], produces[{topic|prefix, at[], conf}], buckets{unresolved, ignored, dynamic})."""
    consumes, produces = [], []
    bk = {"unresolved": [], "ignored": [], "dynamic": []}
    used_props = set()
    prefixes = {}
    for rel in sorted(flat, key=lambda r: (ev_rank(r), r)):
        for e in flat[rel]:
            if e["prop"].split(".")[-1].lower() == "topic-prefix":
                for v in yml_val(e["value"], over).split(","):
                    if TOPIC_RE.fullmatch(v.strip()):
                        prefixes.setdefault(v.strip(), "%s:%d" % (rel, e["line"]))
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
            ts, a = placeholder_values(e, flat, over)
            topics += ts
            yat = yat or a
        if not topics:
            u = {"kind": "kafka_consume", "at": at, "expr": (exprs[0] if exprs else None)}
            text = (code or {}).get("texts", {}).get(r["file"]) or read_rel(repo, r["file"]) or ""
            if re.search(r"subscriptionTopics\s*\(|ReceiverOptions<[^>]*>\s+\w+\s*[,)]", text):
                bk["dynamic"].append(dict(u, reason="consumer wrapper: topics come from the injected ReceiverOptions "
                                                    "(each bean's topic is resolved where it is built)"))
            else:
                bk["unresolved"].append(u)
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
            val = yml_val(e["value"], over)
            have = {c["topic"] for c in consumes}
            for v in [t.strip() for t in val.split(",") if TOPIC_RE.fullmatch(t.strip())]:
                if v not in have:
                    consumes.append({"topic": v, "at": ["%s:%d" % (rel, e["line"])], "conf": "medium"})
    ccons, cprods = code_kafka(code, flat, over, prefixes)
    for c in ccons:  # handler classes (getSupportedTopics & co.)
        if c["topic"] not in {x["topic"] for x in consumes}:
            consumes.append(c)
    consumed = {c["topic"] for c in consumes}
    known = sorted({p["topic"] for p in cprods})
    for r in rows:
        if r.get("kind") != "producer":
            continue
        at = "%s:%d" % (r["file"], r["line"])
        if r.get("topic"):
            produces.append({"topic": r["topic"], "at": [at], "conf": "high"})
            continue
        expr = r.get("topic_expr")
        ts, yat, fe = [], None, None
        if expr:
            fe = value_field_expr(repo, r["file"], expr) if not expr.startswith('"') else None
            if fe:
                for prop, _d in extract.YML_REF_RE.findall(fe):
                    used_props.add(extract.relax(prop))
                ts, yat = placeholder_values(fe, flat, over)
        for t in ts:
            produces.append({"topic": t, "at": [x for x in (at, yat) if x], "conf": "high"})
        if not ts and expr:
            u = {"kind": "kafka_produce", "at": at, "expr": expr[:80]}
            b, why = producer_bucket((code or {}).get("texts", {}).get(r["file"]) or read_rel(repo, r["file"]),
                                     r["file"], fe, ts)
            if b:
                u["reason"] = why
                if b == "dynamic" and known and not why.startswith("dead-letter"):
                    u["topics"] = known[:12]  # the topics this service's call sites name
            bk[b or "unresolved"].append(u)
    have = {p["topic"] for p in produces}
    for p in cprods:  # publisher route tables + outbox saveEvent topics
        if p["topic"] not in have:
            produces.append(p)
            have.add(p["topic"])
    for rel in sorted(flat):
        for e in flat[rel]:
            parts = e["prop"].split(".")
            leaf = parts[-1].lower()
            if "topic" not in leaf:
                continue
            at = "%s:%d" % (rel, e["line"])
            val = yml_val(e["value"], over)
            vals = [t.strip() for t in val.split(",") if TOPIC_RE.fullmatch(t.strip())]
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
    return consumes, produces, bk


def lib_group(repo, files):
    """The Maven group a repo publishes (gradle.properties / build.gradle `group`), or None."""
    for rel in ("gradle.properties", "build.gradle", "build.gradle.kts"):
        if rel in files:
            m = re.search(r"(?m)^\s*group\s*=?\s*['\"]?([\w.\-]+)['\"]?\s*$", read_rel(repo, rel) or "")
            if m:
                return m.group(1)
    return None


def topic_over(man, svc):
    """The deploy manifests' topic-like env values of svc → {ENV: [topics]} (they win over ${ENV:default})."""
    out = {}
    for k, vs in ((man or {}).get("env", {}).get(svc) or {}).items():
        if "TOPIC" in k:
            ts = [t.strip() for v, _ev in vs for t in v.split(",") if TOPIC_RE.fullmatch(t.strip())]
            if ts:
                out[k] = list(dict.fromkeys(ts))
    return out


def build_link(repo, svc, hroot, man=None):
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
    code = code_index(repo, files)
    for hc in contracts.get("http_clients", []):  # a URL key no code reads is dead config, never "unresolved"
        if not prop_bound(hc.get("prop"), code):
            hc["unbound"] = True
        use, use_at = prop_use(hc.get("prop"), code)
        if use:
            hc["use"] = use
        if use_at:
            hc["use_at"] = use_at[:3]
    consumes, produces, bk = kafka_sides(repo, rows, contracts, flat, code, topic_over(man, svc))
    props = {"%s:%d" % (rel, e["line"]): e["prop"] for rel in flat for e in flat[rel]}
    dbs = [d for d in contracts.get("db", [])  # a CDC / migration connector URL is not the service's database
           if not DB_SKIP_SEG.intersection(props.get(d.get("at"), "").lower().split("."))]
    has_mig = any(r.get("kind") == "migration" for r in rows)
    comp = [{k: r[k] for k in ("id", "kind", "name", "fqn", "file", "line", "http", "topic", "topic_expr", "table",
                               "target", "purpose", "tags", "module", "props_prefix", "props", "type")
             if r.get(k) not in (None, "", [])} for r in rows]
    lib = extract.library_info(files, lambda rel: read_rel(repo, rel))
    remote = re.sub(r"://[^/@]*@", "://", (git(repo, "config", "--get", "remote.origin.url") or "").strip()) or None
    return {"schema": SCHEMA, "svc": svc, "path": os.path.relpath(repo, hroot), "source": source,
            "indexed_commit": commit, "remote": remote, "has_migrations": has_mig, "group": lib_group(repo, files),
            "library": lib,
            "contracts": dict({k: contracts.get(k, []) for k in ("http_exposed", "http_clients", "client_targets",
                                                                "libs")}, db=dbs),
            "kafka": {"consumes": consumes, "produces": produces}, "unresolved": bk["unresolved"],
            "ignored": bk["ignored"], "dynamic": bk["dynamic"], "components": comp}


# ---------------------------------------------------------------- deploy manifests (read-only) ----------------
def manifest_dirs(h):
    """aliases.json "manifests": a dir (or list) of deploy manifests, relative to the hub root — helm values.yaml
    (env: {NAME: {value}}) and k8s Deployments (env: [{name, value}])."""
    m = (read_json(os.path.join(h, "aliases.json"), {}) or {}).get("manifests") or []
    m = [m] if isinstance(m, str) else [x for x in m if isinstance(x, str)]
    root = hub_root(h)
    return [os.path.normpath(x if os.path.isabs(x) else os.path.join(root, x)) for x in m]


def keep_manifest_env(key, val):
    """Only addresses and topic names are ever kept: a *_URL/_URI/_HOST value (its host / schema is all the hub
    uses) or a TOPIC key; secret-looking keys, secrets*.yaml and *.enc.yaml are never read into the result."""
    if not val or "${" in val:
        return False
    if re.search(r"_(URL|URI|HOST)$", key):
        return True
    return "TOPIC" in key and not SECRET_KEY.search(key)


def app_base(name):
    return re.sub(r"-(ms|service|svc)$", "", (name or "").lower())


def load_manifests(h, names):
    """→ {env: {svc: {ENV: [(value, evidence)]}}, apps: {deployed name: svc|None}, ns: {namespaces}}. A manifest
    names its service by image repository basename, applicationName / nameOverride / metadata.name, or its dir."""
    man = {"env": {}, "apps": {}, "ns": set()}
    for d in manifest_dirs(h):
        if not os.path.isdir(d):
            continue
        tag = os.path.basename(d.rstrip("/"))
        for dp, ds, fs in os.walk(d):
            ds[:] = sorted(x for x in ds if not x.startswith("."))
            for f in sorted(fs):
                rel = os.path.relpath(os.path.join(dp, f), d)
                if not f.endswith((".yaml", ".yml")) or MANIFEST_SKIP.search(rel):
                    continue
                text = read_rel(d, rel) or ""
                apps, imgs, envs = [], [], []
                for e in extract.yml_flat(text):
                    p, v = e["prop"], e["value"]
                    leaf = p.split(".")[-1]
                    if leaf in ("applicationName", "nameOverride", "fullnameOverride") or p == "metadata.name":
                        apps.append(v)
                    elif leaf in ("namespaceOverride", "namespace"):
                        man["ns"].add(v)
                    elif p.endswith("image.repository"):
                        imgs.append(re.sub(r"[:@].*$", "", v.rsplit("/", 1)[-1]))
                    m = HELM_ENV_RE.search(p)
                    if m:
                        envs.append((m.group(1), v, e["line"]))
                imgs += [re.sub(r"[:@].*$", "", m.rsplit("/", 1)[-1])  # k8s container image: repo/name:tag
                         for m in re.findall(r"(?m)^[ \t-]*image:[ \t]*['\"]?([^'\"\s#]+)", text)]
                for m in K8S_ENV_RE.finditer(text):
                    envs.append((m.group(1), m.group(2).strip(), text.count("\n", 0, m.start()) + 1))
                svc = None
                for x in imgs + apps + [os.path.basename(dp)]:
                    s, c = match_name(x, names)
                    if c != "high":  # aml-ms deployed, aml-service in the hub: one name minus -ms/-service/-svc
                        hits = {k for n, k in names.items() if app_base(n) == app_base(x)}
                        s, c = (hits.pop(), "high") if len(hits) == 1 else (None, None)
                    if c == "high":
                        svc = s
                        break
                for a in apps + imgs:
                    if man["apps"].get(a) is None:
                        man["apps"][a] = svc
                if not svc:
                    continue
                for k, v, ln in envs:
                    if keep_manifest_env(k, v):
                        man["env"].setdefault(svc, {}).setdefault(k, []).append((v, "%s/%s:%d" % (tag, rel, ln)))
    return man


def deployed_target(val, man, names):
    """A manifest URL value → a service, external:<deployed app> (deployed, not registered in the hub),
    external:<public host>, or None (an IP, localhost, an unknown in-cluster name). In-cluster = a bare name,
    <name>.<a manifest namespace>, <deployed app>.<ns> (a namespace set outside the values), or <name>.<ns>.svc[…]."""
    v = (val or "").strip()
    h = host_of(v if "://" in v else "http://" + v)
    if not h or h in LOCAL_HOSTS or re.fullmatch(r"[\d.]+", h):
        return None
    lab = h.split(".")
    if len(lab) == 1 or lab[1] in man["ns"] or "svc" in lab[1:3] or (len(lab) == 2 and lab[0] in man["apps"]):
        a = lab[0]
        if a in man["apps"]:
            return man["apps"][a] or "external:" + a
        s, c = match_name(a, names)
        return s if c == "high" else None
    return "external:" + h


def schema_of(val):
    m = re.search(r"[?&](?:currentSchema|search_path)=([\w\-]+)", val or "")
    return m.group(1) if m else None


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
    return isinstance(d, dict) and not any(v for k, v in d.items() if not k.startswith("_")
                                           and isinstance(v, (dict, list, str)))  # "manifests" is a user edit too


def write_aliases(h, suggested):
    base = {k: {} for k in ALIAS_KEYS}
    doc = dict(base, _suggested=suggested,
               _note="Hub suggestions live in _suggested and are never applied. Copy an entry into env / topic_owner "
                     "/ db_owner / lib_owner to make it win. ignore maps an env name, a topic, or <svc>:<env|topic> "
                     "(one service only) to a reason: those rows go to ignored, never an edge or unresolved. Once "
                     "you edit this file the hub never rewrites it.")
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


def join(links, aliases, man=None):
    """→ (edges, buckets, suggestions). buckets: unresolved (the hub could not decide), ignored (test/local profile
    copies, dead config, UI links, disabled topics) and dynamic (DLT/outbox/wrapper sites, prefixes no one
    consumes) — each ignored/dynamic row carries its reason, so nothing disappears silently."""
    man = man or {"env": {}, "apps": {}, "ns": set()}
    svcs = sorted(links)
    edges, unresolved, sugg = {}, [], {k: {} for k in ALIAS_KEYS}
    ignored, dynamic = [], []
    dirs = {s: repo_dir(links[s], s) for s in svcs}
    names = dict({d: s for s, d in dirs.items()}, **{s: s for s in svcs})  # a key wins over another repo's dir

    def ev(svc, at):
        return "%s/%s" % (dirs.get(svc, svc), at)

    ign = {}  # aliases.ignore: (service or None, env|topic) → reason; a scope may name the repo dir
    for k, why in aliases["ignore"].items():
        sc, _c, ref = k.rpartition(":")
        ign[(names.get(sc, sc) if sc else None, ref)] = "declared in aliases.json: %s" % why

    def declared(s, ref):
        return ign.get((s, ref)) or ign.get((None, ref)) if ref else None

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

    # db owners by schema: the service whose own deployed datasource URL names that schema (unique)
    by_schema = {}
    for s2, envs in man["env"].items():
        for k, vs in envs.items():
            if OWN_DS_ENV.match(k):
                for v, _e in vs:
                    if schema_of(v):
                        by_schema.setdefault(schema_of(v), set()).add(s2)
    schema_owner = {sc: next(iter(o)) for sc, o in by_schema.items() if len(o) == 1}
    # http
    for s in svcs:
        c = links[s]["contracts"]
        senv = man["env"].get(s) or {}
        for h in c.get("http_clients", []):  # another service's datasource (report.datasources.aml.url) → db edge
            env, prop = h.get("env") or "", h.get("prop") or ""
            if not (DATASOURCE_RE.search(env) or DATASOURCE_RE.search(prop)) or prop.startswith("spring.") \
                    or env.startswith("SPRING_") or ev_rank(h["at"]) == 2:
                continue
            hit = False
            for v, mev in senv.get(env, []):
                sc = schema_of(v)
                o = aliases["db_owner"].get(sc) or schema_owner.get(sc) if sc else None
                o = names.get(o, o)
                if o and o != s:
                    add(s, o, "db", sc, [ev(s, h["at"]), mev], "medium")
                    hit = True
            if not hit and not h.get("default_url") and re.search(r"_(URL|URI)$", env):
                ignored.append({"svc": s, "kind": "http_client", "env": env, "at": ev(s, h["at"]),
                                "reason": "datasource URL, not HTTP; no deployed value names a schema owner "
                                          "(aliases.db_owner)"})
        entries = [h for h in c.get("http_clients", []) if is_http_client(h)]
        by_at = {h["at"]: h for h in entries}
        for ct in c.get("client_targets", []):  # a client class whose base URL property resolved (ADR-IDX-4)
            h = by_at.get(ct.get("yml_at"))
            if h is not None:
                h.setdefault("_client_at", []).append(ct["at"])
            elif is_http_client(ct):
                entries.append({"env": ct.get("env"), "default_url": ct.get("default_url"), "prop": ct.get("prop"),
                                "at": ct["yml_at"], "_client_at": [ct["at"]]})
        main_at = {}
        for h in entries:
            if h.get("env") and ev_rank(h["at"]) < 2:
                main_at.setdefault(h["env"], h["at"])
        for h in entries:
            env = h.get("env")
            via = env or h.get("prop") or h.get("key")
            evid = [ev(s, h["at"])] + [ev(s, a) for a in h.get("_client_at", [])]
            u = {"svc": s, "kind": "http_client", "env": env, "at": ev(s, h["at"])}
            if ev_rank(h["at"]) == 2:  # test/local profile: never an edge, never alias-matched
                ignored.append(dict(u, reason=("test/local profile copy of %s" % ev(s, main_at[env])) if env in main_at
                                    else "test/local profile only: no main-profile key declares it"))
                continue
            if declared(s, env):
                ignored.append(dict(u, reason=declared(s, env)))
                continue
            if h.get("use") == "ui" and not h.get("_client_at"):  # evidence from use beats any address it holds
                ignored.append(dict(u, reason="UI link: %s only reaches template/email/notification model data (%s), "
                                              "never an HTTP client base URL"
                                              % (h.get("prop"), ", ".join(ev(s, a) for a in h.get("use_at", [])))))
                continue
            deployed, own = [], False
            if not (env and env in aliases["env"]):  # an alias still wins; else the deploy manifests decide
                for v, mev in senv.get(env, []) if env else []:
                    t = deployed_target(v, man, names)
                    own = own or t == s
                    if t and t != s:
                        deployed.append((t, mev))
            if own and not deployed:
                ignored.append(dict(u, reason="self: the deployed address names %s itself" % s))
                continue
            if deployed:
                for t, mev in deployed:
                    add(s, t, "http", via, evid + [mev], "high")
                if all(t.startswith("external:") for t, _m in deployed):  # stubs/vendors only in the manifests:
                    t0, _c, w0 = http_target(h, names, aliases, s)       # the yml default's public host stays too
                    if t0 and t0.startswith("external:") and w0 == "host":
                        add(s, t0, "http", via, evid, "high")
                continue
            t, conf, why = http_target(h, names, aliases, s)
            if t is None:
                if host_of(h.get("default_url")) not in LOCAL_HOSTS:
                    u["host"] = host_of(h.get("default_url"))
                if h.get("unbound"):
                    ignored.append(dict(u, reason="unused config: no src/main code reads %s" % h.get("prop")))
                elif UI_LINK_RE.search(h.get("prop") or env or "") and h.get("use") != "http":
                    ignored.append(dict(u, reason="UI link (portal/login/deeplink) handed to users, not a service call"))
                else:
                    unresolved.append(u)
                continue
            if t == s:
                ignored.append(dict(u, reason="self: the address names %s itself" % s))
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
                if declared(s, h["env"]):
                    ignored.append({"svc": s, "kind": "http_client", "env": h["env"],
                                    "at": ev(s, "%s:%d" % (r["file"], r["line"])), "reason": declared(s, h["env"])})
                    continue
                t, conf, _w = http_target(h, names, aliases, s)
                if t is None and not m:
                    t, conf = match_name(tt.lower(), names, s)
                if t and t != s:
                    add(s, t, "http", h.get("env") or tt, [ev(s, "%s:%d" % (r["file"], r["line"]))], conf)
    # kafka
    exact, prefixes = {}, []
    matched_prefix, superseded, seen = set(), {}, set()
    for s in svcs:
        own = {c["topic"] for c in links[s]["kafka"]["consumes"]}
        for p in links[s]["kafka"]["produces"]:
            if p.get("topic") and declared(s, p["topic"]):  # a self-consumed topic: its consumer row covers it
                if p["topic"] not in own and (s, p["topic"]) not in seen:
                    seen.add((s, p["topic"]))
                    ignored.append({"svc": s, "kind": "kafka_produce", "topic": p["topic"], "at": ev(s, p["at"][0]),
                                    "reason": declared(s, p["topic"])})
            elif p.get("topic"):
                exact.setdefault(p["topic"], []).append((s, p))
            elif p.get("prefix"):
                prefixes.append((s, p))

    def internal(s, t, at, why):
        if (s, t) not in seen:
            seen.add((s, t))
            ignored.append({"svc": s, "kind": "kafka_consume", "topic": t, "at": at, "reason": why})

    def by_topic(rows):
        out = {}
        for p in rows:
            if p.get("topic"):
                out.setdefault(p["topic"], []).extend(p["at"][:1])
        return out
    for s in svcs:
        for cns in links[s]["kafka"]["consumes"]:
            t = cns["topic"]
            if declared(s, t):
                internal(s, t, ev(s, cns["at"][0]), declared(s, t))
                continue
            owner = aliases["topic_owner"].get(t)
            owner = names.get(owner, owner)
            cev = [ev(s, a) for a in cns["at"]]
            if owner:
                add(owner, s, "kafka", t, cev, "high")
                continue
            prods = [(ps, p) for ps, p in exact.get(t, []) if ps != s]
            if prods:
                for ps, p in prods:
                    cf = min(p["conf"], cns.get("conf", "high"), key=lambda c: CONF_W[c])
                    add(ps, s, "kafka", t, [ev(ps, a) for a in p["at"]] + cev, cf)
                    if p.get("via_prefix"):  # topic = prefix + event type: the prefix line is on the edge
                        matched_prefix.add((ps, p["via_prefix"]))
                    else:  # the publisher names the topic itself: a same-service prefix it starts with is bypassed
                        for xs, x in prefixes:
                            if xs == ps and t.startswith(x["prefix"]):
                                superseded.setdefault((ps, x["prefix"]), set()).add("%s → %s" % (t, s))
                continue
            if any(ps == s for ps, _p in exact.get(t, [])):
                internal(s, t, cev[0], "internal topic: %s produces and consumes %s itself" % (s, t))
                continue
            pm = [(ps, p) for ps, p in prefixes if t.startswith(p["prefix"])]
            if pm:
                longest = max(len(p["prefix"]) for _s, p in pm)
                pm = [(ps, p) for ps, p in pm if len(p["prefix"]) == longest]
            if any(ps == s for ps, _p in pm):
                internal(s, t, cev[0], "internal topic: %s consumes %s under its own outbox topic-prefix %s"
                         % (s, t, pm[0][1]["prefix"]))
                continue
            if len(pm) == 1:
                ps, p = pm[0]
                matched_prefix.add((ps, p["prefix"]))
                add(ps, s, "kafka", t, [ev(ps, a) for a in p["at"]] + cev, "medium")
                sugg["topic_owner"][t] = ps
                continue
            if (s, t) not in seen:
                seen.add((s, t))
                unresolved.append({"svc": s, "kind": "kafka_consume", "topic": t, "at": cev[0]})
    for ps, p in prefixes:
        k = (ps, p["prefix"])
        if k in matched_prefix or k in seen:
            continue
        seen.add(k)
        if k in superseded:
            sup = sorted(superseded[k])
            why = ("outbox topic-prefix superseded: the publisher routes these topics explicitly (%s%s), so no "
                   "consumed topic is composed from %s" % (", ".join(sup[:4]), " +%d" % (len(sup) - 4)
                                                            if len(sup) > 4 else "", p["prefix"]))
        else:
            why = "outbox topic-prefix: no other registered service consumes a %s* topic" % p["prefix"]
        dynamic.append({"svc": ps, "kind": "kafka_produce", "prefix": p["prefix"], "at": ev(ps, p["at"][0]),
                        "reason": why})
    linked = {(e["from"], e["via"]) for e in edges.values() if e["type"] == "kafka"}
    for ps in svcs:  # a static topic no registered consumer names: not a link, but never dropped silently
        own = {c["topic"] for c in links[ps]["kafka"]["consumes"]}
        for t, ats in sorted(by_topic(links[ps]["kafka"]["produces"]).items()):
            if (ps, t) not in linked and (ps, t) not in seen:
                seen.add((ps, t))
                ignored.append({"svc": ps, "kind": "kafka_produce", "topic": t, "at": ev(ps, ats[0]), "reason": (
                    "internal topic: %s produces and consumes %s itself; no other registered service consumes it"
                    % (ps, t)) if t in own else "no registered service's consumer side names %s" % t})
    for s in svcs:
        for key, out in (("unresolved", unresolved), ("ignored", ignored), ("dynamic", dynamic)):
            for u in links[s].get(key, []):
                why = declared(s, u.get("topic") or u.get("env")) if key == "unresolved" else None
                (ignored if why else out).append(dict(u, svc=s, at=ev(s, u["at"]), **({"reason": why} if why else {})))
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
    for s in svcs:  # a detected multi-module publisher owns its group
        li = links[s].get("library")
        if li and li.get("group"):
            owners[li["group"]] = s
    owners.update({g: names.get(o, o) for g, o in aliases["lib_owner"].items()})
    for s in svcs:
        for k, e in lib_edges(s, links, owners).items():
            if e["to"] == s:
                continue
            add(s, e["to"], "lib", k, e["evidence"], "high")
            edges[(s, e["to"], "lib", k)].update({x: v for x, v in e.items() if x not in ("to", "evidence")})
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
        owner = names.get(owner, owner)
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
    for b in (unresolved, ignored, dynamic):
        b.sort(key=lambda u: (u["svc"], u["kind"], u.get("at") or ""))
    return out, {"unresolved": unresolved, "ignored": ignored, "dynamic": dynamic}, \
        {k: dict(sorted(v.items())) for k, v in sugg.items() if v}


def lib_edges(s, links, owners):
    """Service s → {coord: {to, module, version?, version_src?, bom_version?, bom?, scope?, missing?, evidence[]}} for
    every dependency whose group has an owner. One entry per module (implementation + testImplementation merge)."""
    def ev(at):
        return "%s/%s" % (repo_dir(links[s], s), at)
    libs = [l for l in links[s]["contracts"].get("libs", []) if l["coord"].split(":")[0] in owners]
    boms = {}
    for l in libs:  # the service's platform/BOM per group (a main-scope one wins)
        g = l["coord"].split(":")[0]
        if l.get("platform") and l.get("version") and (g not in boms or boms[g].get("scope") == "test"):
            boms[g] = l
    out = {}
    for l in libs:
        g, a = l["coord"].split(":", 1)
        owner = owners[g]
        li = (links.get(owner) or {}).get("library") or {}
        mod = next((m for m in li.get("modules") or [] if m["artifact"] == a), None)
        e = out.setdefault(l["coord"], {"to": owner, "module": a, "evidence": [], "_scopes": set()})
        e["evidence"].append(ev(l["at"]))
        e["_scopes"].add(l.get("scope") or "main")
        if l.get("platform"):
            e["bom"] = True
        if l.get("version") and "version" not in e:
            e.update(version=l["version"], version_src=l.get("version_src") or "explicit")
        if li and mod is None:
            e["missing"] = True
    for coord, e in out.items():
        g = coord.split(":")[0]
        b = boms.get(g)
        if "version" not in e and b and not e.get("bom"):
            mod = next((m for m in ((links.get(e["to"]) or {}).get("library") or {}).get("modules") or []
                        if m["artifact"] == e["module"]), None)
            e.update(version_src="bom", bom_version=b["version"])
            if not (mod and mod.get("version")):  # a module versioned apart from the BOM (payment-sdk) has no BOM version
                e["version"] = b["version"]
            e["evidence"].append(ev(b["at"]))
        sc = e.pop("_scopes")
        if sc == {"test"}:
            e["scope"] = "test"
        e["evidence"] = list(dict.fromkeys(e["evidence"]))
    return out


def vkey(v):
    """Numeric version order: 0.3.9 < 0.3.10; a non-numeric tail sorts after its numbers."""
    return tuple((0, int(p)) if p.isdigit() else (1, p) for p in re.split(r"[.\-+]", v or ""))


def eff_version(e):
    return e.get("version") or ("bom %s" % e["bom_version"] if e.get("bom_version") else "?")


def lib_summary(edges, links=None):
    """owner → {group, version, modules:{artifact: {svc: edge}}, consumers:set, published:[artifacts]}."""
    out = {}
    for e in edges:
        if e["type"] != "lib":
            continue
        o = out.setdefault(e["to"], {"group": e["via"].split(":")[0], "modules": {}, "consumers": set()})
        o["modules"].setdefault(e.get("module") or e["via"].split(":", 1)[-1], {})[e["from"]] = e
        o["consumers"].add(e["from"])
    for owner, o in out.items():
        li = ((links or {}).get(owner) or {}).get("library") or {}
        o["version"] = li.get("version")
        o["published"] = [m["artifact"] for m in li.get("modules") or []]
        o["root"] = li.get("root")
    return out


def skewed(mods):
    """{svc: edge} → sorted distinct effective versions (numeric order)."""
    return sorted({eff_version(e) for e in mods.values()}, key=lambda v: vkey(v.replace("bom ", "")))


# ---------------------------------------------------------------- outputs -------------------------------------
def lib_md_lines(edges, links=None):
    """HUB.md "Shared libraries": one line per library owner — modules used, consumers, BOM / version skew."""
    L = []
    for owner, o in sorted(lib_summary(edges, links).items()):
        bom = [vs for a, m in o["modules"].items() if any(e.get("bom") for e in m.values()) for vs in [skewed(m)]]
        sk = sorted(a for a, m in o["modules"].items() if len(skewed(m)) > 1 and not any(e.get("bom") for e in m.values())
                    and not all(e.get("version_src") == "bom" for e in m.values()))  # BOM-managed: the BOM's skew
        parts = ["%d module(s) used by %d service(s)" % (len(o["modules"]), len(o["consumers"]))]
        if bom:
            vs = bom[0]
            parts.append("BOM %s%s" % (vs[0] if len(vs) == 1 else "%s…%s (%d versions, skew)" % (vs[0], vs[-1], len(vs)), ""))
        if sk:
            parts.append("skew: " + ", ".join(sk[:4]) + (" +%d" % (len(sk) - 4) if len(sk) > 4 else ""))
        L.append("- %s (%s%s): %s" % (owner, o["group"], " @" + o["version"] if o.get("version") else "", "; ".join(parts)))
    return L


def hub_md(h, services, edges, buckets, links=None):
    buckets = buckets if isinstance(buckets, dict) else {"unresolved": buckets}
    hroot = hub_root(h)
    L = ["# Hub — %d services, %d edges" % (len(services), len(edges)),
         "Service paths are relative to the hub root `%s`; evidence is `<repo dir>/<file>:<line>`. Full data: "
         "`.claude/claudehut/hub/service-links.json`; query with `claudehut-index links|svc <name>`."
         % os.path.basename(hroot), "", "## Services"]
    for s in sorted(services):
        m = services[s]
        L.append("- %s `%s` @%s%s" % (s, m.get("path"), (m.get("indexed_commit") or "none")[:7],
                                     "" if m.get("has_plane") else " (hub-scan)"))
    libl = lib_md_lines(edges, links)
    if libl:
        L += ["", "## Shared libraries (per-module edges: `claudehut-index svc <library>`, `links --type lib`)"] + libl
    L += ["", "## Edges (from → to · type · via · confidence)"]
    rest = []
    for e in edges:
        if e["type"] == "lib" and libl:
            continue
        rest.append("- %s → %s · %s · %s · %s" % (e["from"], e["to"], e["type"], e["via"], e["confidence"]))
    tail = ["", "Unresolved: %d (fix with aliases.json) · ignored %d · dynamic %d (each with its reason in "
            "service-links.json)." % tuple(len(buckets.get(k, [])) for k in ("unresolved", "ignored", "dynamic"))]
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
        elif e["type"] == "lib":  # one node per library module; the owner contains it, a consumer depends on it
            mod = e.get("module") or e["via"].split(":", 1)[-1]
            m = node("module:" + e["via"], "module", mod, "Library module %s (owner %s)" % (e["via"], e["to"]),
                     ["lib"] + (["bom"] if e.get("bom") else []))
            gedge(a, m, "depends_on", e["confidence"])
            gedges[-1]["description"] = "uses %s @%s%s" % (e["via"], eff_version(e), " (%s)" % e["version_src"]
                                                           if e.get("version_src") and e.get("version") else "")
            if not e.get("missing"):
                gedge(svc_node(e["to"]), m, "contains", e["confidence"])
                gedges[-1]["description"] = "publishes %s" % e["via"]
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
                                 ("layer:libs", "Shared libraries", "module", "Library modules used by services"),
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


def dedupe_services(hroot, services):
    """One entry per repo. A repo hub-scanned under its dir name (ekyc-int-ms) and later init'd under its build name
    (kyc-ms) is registered twice with one path; every edge then doubles. Keep the key the repo's plane names
    (topology.json service, svc_name), else the entry with a plane, else the first key; a dropped entry only fills
    fields the kept one lacks. The dir name stays an alias of the kept key (repo_dir). Returns the dropped keys."""
    by_repo = {}
    for k in sorted(services):
        by_repo.setdefault(os.path.realpath(os.path.join(hroot, services[k].get("path") or k)), []).append(k)
    dropped = []
    for repo, keys in sorted(by_repo.items()):
        if len(keys) < 2:
            continue
        name = svc_name(repo) if os.path.isdir(repo) else None
        keep = name if name in keys else next((k for k in keys if services[k].get("has_plane")), keys[0])
        for k in keys:
            if k != keep:
                for f, v in services.pop(k).items():
                    if services[keep].get(f) is None:
                        services[keep][f] = v
                dropped.append(k)
    return dropped


def prune_links(h, services):
    """links/ is hub-sync's own output: a file whose service is no longer registered (a deduped key, or one init
    dropped from services.json) goes, so no reader sees the old name. A registered but missing repo keeps its file."""
    d = os.path.join(h, "links")
    try:
        names = os.listdir(d)
    except OSError:
        return
    for n in names:
        if n.endswith(".json") and n[:-5] not in services:
            try:
                os.remove(os.path.join(d, n))
            except OSError:
                pass


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
        dedupe_services(hroot, services)
        links, missing = {}, []
        man = load_manifests(h, dict({os.path.basename((services[k].get("path") or k).rstrip("/")) or k: k
                                      for k in services}, **{k: k for k in services}))
        for s in sorted(services):
            repo = os.path.normpath(os.path.join(hroot, services[s].get("path") or s))
            if not os.path.isdir(repo):
                missing.append(s)
                continue
            lk_doc = build_link(repo, s, hroot, man)
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
        prune_links(h, services)
        aliases = load_aliases(h)
        edges, buckets, sugg = join(links, aliases, man)
        write_aliases(h, sugg)
        write_if_changed(os.path.join(h, "services.json"), dumps(dict(other, **services)))
        write_if_changed(os.path.join(h, "service-links.json"),
                         dumps(dict({"schema": SCHEMA, "edges": edges}, **buckets)))
        write_if_changed(os.path.join(h, "HUB.md"), hub_md(h, {k: services[k] for k in links}, edges, buckets, links))
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
            "by_type": counts, "unresolved": len(buckets["unresolved"]), "ignored": len(buckets["ignored"]),
            "dynamic": len(buckets["dynamic"]), "elapsed_ms": int((time.time() - t0) * 1000)}


def summary_line(r):
    if not r.get("synced"):
        return "hub: sync skipped — %s" % r.get("reason")
    bt = ", ".join("%s %d" % (k, r["by_type"].get(k, 0)) for k in ("http", "kafka", "lib", "db"))
    miss = " · missing: %s" % ", ".join(r["missing"]) if r["missing"] else ""
    return "hub: synced %d services, %d edges (%s), %d unresolved, %d ignored, %d dynamic (%d ms) → %s%s" % (
        r["services"], r["edges"], bt, r["unresolved"], r.get("ignored", 0), r.get("dynamic", 0), r["elapsed_ms"],
        r["hub"], miss)


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


def library_lines(link, edges, by):
    """svc <library>: its surface counts, then modules × consumers × versions (skew = >1 version in use; a BOM-managed
    module follows the service's BOM line, so only its consumer count is printed)."""
    s, li = link["svc"], link.get("library")
    o = lib_summary(edges, {s: link}).get(s)
    if not li and not o:
        return []
    L = []
    if li:
        kinds = ["module", "autoconfig", "properties", "annotation", "spi", "bean"]
        L.append("Library %s%s · %d modules · %s — find --svc %s <term>" % (
            li["group"], " @" + li["version"] if li.get("version") else "", len(li.get("modules") or []),
            ", ".join("%s %d" % (k, len(by[k])) for k in kinds if by.get(k)) or "no surface rows", s))
    if not o:
        return L
    pre = (li or {}).get("root")
    short = lambda a: a[len(pre) + 1:] if pre and a.startswith(pre + "-") else a  # noqa: E731
    L.append("Modules × consumers × versions (%d services; who uses one: links --module <name>):" % len(o["consumers"]))
    rows, newer = [], set()
    own = {x["artifact"]: x.get("version") for x in (li or {}).get("modules") or []}
    for a, m in sorted(o["modules"].items(), key=lambda x: (not any(e.get("bom") for e in x[1].values()), x[0])):
        vs = skewed(m)
        bomonly = all(e.get("version_src") == "bom" for e in m.values())
        tag = "[bom] " if any(e.get("bom") for e in m.values()) else ""
        if bomonly:
            rows.append("- %s%s %d svc (bom)" % (tag, short(a), len(m)))
            continue
        by_v = {}
        for svc, e in m.items():
            by_v.setdefault(eff_version(e), []).append(svc)
            cur = own.get(a) or o.get("version")  # a module versioned apart (payment-sdk) has its own repo version
            if cur and e.get("version") and vkey(e["version"]) > vkey(cur):
                newer.add("%s %s %s>%s" % (svc, short(a), e["version"], cur))
        rows.append("- %s%s %d svc%s: %s" % (tag, short(a), len(m), " SKEW" if len(vs) > 1 else "", " · ".join(
            "%s %s" % (v, ",".join(sorted(by_v[v]))) for v in vs)))
    L += rows
    if o.get("published"):
        unused = [short(a) for a in o["published"] if a not in o["modules"]]
        if unused:
            L.append("Unused modules: " + ", ".join(unused))
    miss = sorted(short(a) for a, m in o["modules"].items() if any(e.get("missing") for e in m.values()))
    if miss:
        L.append("Not published by this repo: " + ", ".join(miss))
    if newer:
        L.append("Newer than this repo's version: " + ", ".join(sorted(newer)))
    return L


def render_svc(link, edges, stale_note, repo, budget=2499):
    """repo: the service's absolute root — every path below is relative to it (printed once in the header)."""
    s = link["svc"]
    c = link["contracts"]
    by = {}
    for r in link["components"]:
        by.setdefault(r["kind"], []).append(r)
    L = ["# %s (hub · %s@%s)%s" % (s, link["source"], (link.get("indexed_commit") or "none")[:7], stale_note),
         "repo: %s (paths below are relative to it)" % repo]
    L += library_lines(link, edges, by)
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
        more = " +%d" % (len(seen) - 14) if len(seen) > 14 else ""
        return ", ".join("%s(%s %s)" % (p, t, c) for (p, t), c in list(seen.items())[:14]) + more
    if out_e:
        L.append("Calls/uses: " + peers(out_e, "to"))
    if in_e:
        L.append("Used by: " + peers(in_e, "from"))
    mine = [e for e in out_e if e["type"] == "lib"]
    for owner in sorted({e["to"] for e in mine}):
        es = sorted((e for e in mine if e["to"] == owner), key=lambda e: e["via"])
        L.append("Libs from %s: %s" % (owner, ", ".join("%s %s%s" % (e.get("module"), eff_version(e),
                                                                       " [test]" if e.get("scope") == "test" else "")
                                                         for e in es)))
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
