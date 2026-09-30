"""extract.py — deterministic Spring component extraction for claudehut-index (07-index-memory.md §4.2, ADR-IDX-1).

python3 stdlib only. No LLM ever writes the index: every row comes from a rule in the tables below, with the
repo-relative file and the 1-based line of the annotation / call that produced it.

Rule tables: one rule per line, each tagged `# rule:<name>`. evals/regress/index-tests.sh deletes one tagged
line at a time from a copy of this file and checks that the rule's probe disappears, so a rule can never be
removed silently. Keep one rule per line.

Row shape (the shared contract): {id, kind, name, file, line, fqn?, http?:{method,path}, topic?, table?, target?}
plus extras: svc, annotations[], methods[] (≤12), purpose (first Javadoc sentence), topic_prop, tables[].
"""
import bisect
import re

# ---------------------------------------------------------------- source filters ----------------------------
JAVA_RE = re.compile(r"(^|/)src/main/(.+/)?[^/]+\.java$")
MIGRATION_RE = re.compile(r"(^|/)src/main/resources/db/migration/(.+/)?[^/]+\.sql$")
CONTRACT_RE = re.compile(r"(^|/)(src/main/resources/application[^/]*\.ya?ml|[^/]*\.gradle(\.kts)?|pom\.xml)$")
EXCLUDE_RE = re.compile(r"(^|/)(build|target|out|\.gradle|node_modules)/")


def excluded(path):
    """Build output dirs are excluded only BEFORE src/main/: a package named out/build/target (hexagonal
    adapter/out/…) is source."""
    i = path.find("src/main/")
    return bool(EXCLUDE_RE.search(path[:i] if i >= 0 else path))


def is_source(path):
    """A file whose content produces components (java under src/main, Flyway migrations)."""
    return not excluded(path) and bool(JAVA_RE.search(path) or MIGRATION_RE.search(path))


def is_contract_input(path):
    return not excluded(path) and bool(CONTRACT_RE.search(path))


# ---------------------------------------------------------------- rule tables -------------------------------
# Class kind: first matching rule wins. ann = annotation simple names on the type, ext = extends/implements
# text, uses = the HTTP-client / Kafka-producer type names referenced in the body.
CLASS_RULES = [
    ("controller", lambda t: bool(t["ann"] & {"RestController", "Controller"})),  # rule:controller
    ("client", lambda t: bool(t["ann"] & {"FeignClient", "HttpExchange"})),  # rule:feign-client
    ("repository", lambda t: "Repository" in t["ann"]),  # rule:repository-annotation
    ("repository", lambda t: t["kw"] == "interface" and bool(REPO_EXT_RE.search(strip_type_params(t["ext"])))),  # rule:repository-extends
    ("entity", lambda t: bool(t["ann"] & {"Entity", "Table", "Document"})),  # rule:entity
    ("config", lambda t: bool(t["ann"] & {"Configuration", "ConfigurationProperties"})),  # rule:config
    ("client", lambda t: bool(t["uses"] & HTTP_CLIENT_TYPES) and not (t["ann"] & {"Service"})),  # rule:http-client
    ("service", lambda t: "Service" in t["ann"]),  # rule:service
    ("component", lambda t: bool(t["ann"] & {"Component", "RestControllerAdvice", "ControllerAdvice", "Aspect"})),  # rule:component
]
REPO_EXT_RE = re.compile(r"\b(Jpa|R2dbc|Crud|ReactiveCrud|ReactiveSorting|PagingAndSorting|ListCrud|ListPagingAndSorting|Mongo|ReactiveMongo|Elasticsearch)?Repository\s*<")


def strip_type_params(ext):
    """Drop a leading `<...>` type-parameter list, so `<R extends R2dbcRepository<E, ID>>` is not an extends clause."""
    t = ext.lstrip()
    if not t.startswith("<"):
        return ext
    depth = 0
    for i, c in enumerate(t):
        depth += (c == "<") - (c == ">")
        if depth == 0:
            return t[i + 1:]
    return ""


HTTP_CLIENT_TYPES = {"WebClient", "RestTemplate", "RestClient"}
KAFKA_PRODUCER_TYPES = {"KafkaTemplate", "ReactiveKafkaProducerTemplate", "KafkaSender", "KafkaProducer"}

# Member rules: (kind, annotation names). Endpoint rows carry http, listener rows carry topic.
MAPPING = {
    "GetMapping": "GET",  # rule:get-mapping
    "PostMapping": "POST",  # rule:post-mapping
    "PutMapping": "PUT",  # rule:put-mapping
    "DeleteMapping": "DELETE",  # rule:delete-mapping
    "PatchMapping": "PATCH",  # rule:patch-mapping
    "RequestMapping": None,  # rule:request-mapping
}
LISTENER_ANN = {"KafkaListener"}  # rule:kafka-listener
ROUTER_RETURN_RE = re.compile(r"\bRouterFunction\s*<")  # rule:router-function
SEND_RE = re.compile(r"\b(\w+)\s*\.\s*(send|sendDefault)\s*\(")  # rule:kafka-send
BASE_URL_RE = re.compile(r"\.\s*(baseUrl|rootUri)\s*\(")  # rule:client-base-url
CREATE_TABLE_RE = re.compile(r"\b(create\s+table(?:\s+if\s+not\s+exists)?|alter\s+table(?:\s+if\s+exists)?(?:\s+only)?)\s+([\"\w.]+)", re.I)  # rule:flyway-table

KIND_ORDER = ["controller", "endpoint", "router", "service", "listener", "producer", "client", "repository",
              "entity", "config", "migration", "component"]

MODIFIERS = r"(?:(?:public|protected|private|static|final|abstract|sealed|non-sealed|default|synchronized|strictfp|native|transient|volatile)\s+)*"
TYPE_DECL_RE = re.compile(r"(?<![\w.@])(class|interface|enum|record)\s+([A-Za-z_$][\w$]*)")
ANN_RE = re.compile(r"@(?!interface\b)([A-Za-z_$][\w$.]*)")
PKG_RE = re.compile(r"^\s*package\s+([\w.]+)\s*;", re.M)
IDENT_BEFORE_PAREN_RE = re.compile(r"([A-Za-z_$][\w$]*)\s*$")
FIELD_TYPE_RE = re.compile(r"\b([A-Z]\w*)\s*(?:<[^;{}()]*?>)?\s+(\w+)\s*[;=,)]")
CONST_RE = re.compile(r'\bstatic\s+final\s+String\s+(\w+)\s*=\s*"((?:[^"\\\n]|\\.)*)"\s*;')
STRING_RE = re.compile(r'"((?:[^"\\\n]|\\.)*)"')


# ---------------------------------------------------------------- lexer --------------------------------------
def lex(src):
    """Return (code, skel, javadocs). code: comments blanked (newlines kept); skel: code with string/char
    contents blanked too (quotes kept), for structure. javadocs: [(start, end, text)] of /** */ comments."""
    n = len(src)
    code = list(src)
    skel = list(src)
    docs = []
    i = 0
    while i < n:
        c = src[i]
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            j = src.find("\n", i)
            j = n if j < 0 else j
            for k in range(i, j):
                code[k] = skel[k] = " "
            i = j
        elif c == "/" and i + 1 < n and src[i + 1] == "*":
            j = src.find("*/", i + 2)
            j = n if j < 0 else j + 2
            if src.startswith("/**", i) and not src.startswith("/**/", i):
                docs.append((i, j, src[i:j]))
            for k in range(i, j):
                if src[k] != "\n":
                    code[k] = skel[k] = " "
            i = j
        elif src.startswith('"""', i):
            j = src.find('"""', i + 3)
            j = n if j < 0 else j + 3
            for k in range(i + 3, max(i + 3, j - 3)):
                if src[k] != "\n":
                    skel[k] = " "
            i = j
        elif c == '"' or c == "'":
            j = i + 1
            while j < n and src[j] != c and src[j] != "\n":
                j += 2 if src[j] == "\\" else 1
            for k in range(i + 1, min(j, n)):
                skel[k] = " "
            i = j + 1
        else:
            i += 1
    return "".join(code), "".join(skel), docs


class Src:
    def __init__(self, text):
        self.text = text
        self.code, self.skel, self.docs = lex(text)
        self.nl = [m.start() for m in re.finditer("\n", text)]
        self.opens = [m.start() for m in re.finditer(r"\{", self.skel)]
        self.closes = [m.start() for m in re.finditer(r"\}", self.skel)]
        self.popen = [m.start() for m in re.finditer(r"\(", self.skel)]
        self.pclose = [m.start() for m in re.finditer(r"\)", self.skel)]
        self.bounds = [m.start() for m in re.finditer(r"[;{}]", self.skel)]

    def line(self, pos):
        return bisect.bisect_left(self.nl, pos) + 1

    def depth(self, pos):
        return bisect.bisect_left(self.opens, pos) - bisect.bisect_left(self.closes, pos)

    def pdepth(self, pos):
        return bisect.bisect_left(self.popen, pos) - bisect.bisect_left(self.pclose, pos)

    def stmt_start(self, pos):
        """Just after the last ; { } before pos at the same paren depth (so array initialisers inside
        annotation arguments do not cut the annotation run)."""
        want = self.pdepth(pos)
        i = bisect.bisect_left(self.bounds, pos) - 1
        while i >= 0:
            b = self.bounds[i]
            if self.pdepth(b) == want:
                return b + 1
            i -= 1
        return 0

    def match(self, pos, o, c):
        """pos at an opening char in skel → index of its matching close (or len)."""
        d = 0
        s = self.skel
        for k in range(pos, len(s)):
            if s[k] == o:
                d += 1
            elif s[k] == c:
                d -= 1
                if d == 0:
                    return k
        return len(s)


# ---------------------------------------------------------------- annotation parsing --------------------------
def split_top(text):
    """Split an argument list on top-level commas (strings and nested brackets respected)."""
    parts, depth, cur, q = [], 0, [], None
    for ch in text:
        if q:
            cur.append(ch)
            if ch == q and (len(cur) < 2 or cur[-2] != "\\"):
                q = None
            continue
        if ch in "\"'":
            q = ch
        elif ch in "({[":
            depth += 1
        elif ch in ")}]":
            depth -= 1
        elif ch == "," and depth == 0:
            parts.append("".join(cur))
            cur = []
            continue
        cur.append(ch)
    if "".join(cur).strip():
        parts.append("".join(cur))
    return parts


def parse_args(text):
    """Annotation argument text → {name: raw value text}. The positional value is key 'value'."""
    out = {}
    for p in split_top(text):
        m = re.match(r"\s*([A-Za-z_]\w*)\s*=(?!=)(.*)$", p, re.S)
        key, val = (m.group(1), m.group(2)) if m else ("value", p)
        out.setdefault(key, val.strip())
    return out


def strings(val):
    return [s.encode().decode("unicode_escape") if "\\" in s else s for s in STRING_RE.findall(val or "")]


def split_prop(expr):
    """"${a.b:default}" → (default or None, 'a.b'); a literal → (literal, None)."""
    m = re.fullmatch(r"\$\{([^}:]+)(?::([^}]*))?\}", expr.strip())
    if m:
        return (m.group(2) if m.group(2) not in (None, "") else None), m.group(1)
    return expr, None


def annotations(src, lo, hi):
    """Annotations whose '@' lies in skel[lo:hi] → [(name, args_dict_or_None, at_pos, end_pos)]."""
    res = []
    for m in ANN_RE.finditer(src.skel, lo, hi):
        name = m.group(1).split(".")[-1]
        end = m.end()
        k = end
        while k < len(src.skel) and src.skel[k] in " \t\r\n":
            k += 1
        args = None
        if k < len(src.skel) and src.skel[k] == "(":
            close = src.match(k, "(", ")")
            args = parse_args(src.code[k + 1:close])
            end = close + 1
        res.append((name, args, m.start(), end))
    return res


def leading_annotations(src, pos):
    """The annotations of the declaration that starts at pos (from the previous statement boundary)."""
    return annotations(src, src.stmt_start(pos), pos)


def first_doc_sentence(text):
    t = re.sub(r"^/\*\*|\*/$", "", text)
    t = re.sub(r"(?m)^\s*\*\s?", "", t)
    t = t.split("\n@")[0]
    t = re.sub(r"\{@\w+\s+([^}]*)\}", r"\1", t)
    t = re.sub(r"<[^>]+>", "", t)
    t = " ".join(t.split())
    m = re.match(r"(.+?[.!?])(\s|$)", t)
    t = m.group(1) if m else t
    return t[:160]


# ---------------------------------------------------------------- java extraction -----------------------------
def extract_java(rel, text, svc):
    src = Src(text)
    pm = PKG_RE.search(src.code)
    pkg = pm.group(1) if pm else ""
    types = []
    for m in TYPE_DECL_RE.finditer(src.skel):
        kw, name = m.group(1), m.group(2)
        body = src.skel.find("{", m.end())
        if body < 0:
            continue
        if ";" in src.skel[m.end():body] and kw != "record":
            continue
        end = src.match(body, "{", "}")
        types.append({"kw": kw, "name": name, "at": m.start(), "body": body, "end": end,
                      "ext": src.code[m.end():body]})
    # fqn by nesting
    for t in types:
        outer = [o for o in types if o["body"] < t["at"] < o["end"]]
        outer.sort(key=lambda o: o["body"])
        t["fqn"] = ".".join([x for x in [pkg] + [o["name"] for o in outer] + [t["name"]] if x])
        t["depth"] = src.depth(t["body"]) + 1  # depth of the type's members
    rows = []
    for t in types:
        anns = leading_annotations(src, t["at"])
        t["ann_list"] = anns
        t["ann"] = {a[0] for a in anns}
        at = anns[0][2] if anns else t["at"]
        t["line"] = src.line(at)
        inner = [(o["body"], o["end"]) for o in types if t["body"] < o["at"] < t["end"]]
        body_code = src.skel[t["body"]:t["end"]]
        t["uses"] = set(re.findall(r"\b([A-Z]\w*)\b", body_code + " " + t["ext"])) & (HTTP_CLIENT_TYPES | KAFKA_PRODUCER_TYPES)
        members = member_decls(src, t, inner)
        kind = next((k for k, pred in CLASS_RULES if pred(t)), None)
        purpose = doc_before(src, at)
        base = {"svc": svc, "file": rel}
        if kind:
            row = dict(base, id="%s:%s" % (svc, t["fqn"]), kind=kind, name=t["name"], fqn=t["fqn"], line=t["line"],
                       annotations=sorted(t["ann"]),
                       methods=[mm["name"] for mm in members if mm["public"]][:12])
            if purpose:
                row["purpose"] = purpose
            if kind == "entity":
                tab = table_name(t["ann_list"])
                if tab:
                    row["table"] = tab
            if kind == "client":
                row["target"] = client_target(src, t)
            rows.append(row)
        rows.extend(member_rows(src, t, members, base, kind))
        rows.extend(producer_rows(src, t, inner, base))
    return rows


def doc_before(src, pos):
    i = bisect.bisect_left([d[1] for d in src.docs], pos + 1) - 1
    if i < 0:
        return ""
    s, e, txt = src.docs[i]
    if src.skel[e:pos].strip():
        return ""
    return first_doc_sentence(txt)


def member_decls(src, t, inner):
    """Direct methods of type t: [{name, anns, at, line, public, ret}] (constructors and calls excluded)."""
    out = []
    s = src.skel
    for m in re.finditer(r"\(", s[t["body"] + 1:t["end"]]):
        p = t["body"] + 1 + m.start()
        if src.depth(p) != t["depth"] or src.pdepth(p) != 0 or any(lo < p < hi for lo, hi in inner):
            continue
        stmt = src.stmt_start(p)
        head = s[stmt:p]
        if re.search(r"@[\w$.]+\s*$", head):
            continue
        idm = IDENT_BEFORE_PAREN_RE.search(head)
        if not idm:
            continue
        name = idm.group(1)
        if name in NOT_METHOD or name == t["name"]:
            continue
        anns = annotations(src, stmt, p)
        pre = head
        for a in anns:
            pre = pre[:a[2] - stmt] + " " * (a[3] - a[2]) + pre[a[3] - stmt:]
        if "=" in pre or len(pre.split()) < 2 or re.search(r"\b(class|record|interface|enum|new)\b", pre):
            continue  # a field initialiser, an enum constant or a bare call, not a declaration
        at = anns[0][2] if anns else stmt + (len(head) - len(head.lstrip()))
        out.append({"name": name, "anns": anns, "at": at, "line": src.line(at),
                    "public": re.search(r"\bpublic\b", pre) is not None or t["kw"] == "interface", "ret": pre})
    return out


NOT_METHOD = {"if", "for", "while", "switch", "catch", "synchronized", "return", "new", "super", "this", "throw"}


def join_path(base, path):
    base = (base or "").strip()
    path = (path or "").strip()
    if not base:
        return path or "/"
    if not path:
        return base
    return base.rstrip("/") + "/" + path.lstrip("/")


def mapping_paths(args, consts=None):
    """Literal paths of a mapping; a constant of the same file is resolved, any other expression is kept
    verbatim as <Expr> (never guessed)."""
    if not args:
        return [""]
    out = []
    for key in ("value", "path"):
        raw = args.get(key, "").strip()
        if not raw:
            continue
        if raw.startswith(("\"", "{")) and strings(raw):
            out += strings(raw)
            continue
        name = raw.strip("{} ").split(".")[-1]
        out.append((consts or {}).get(name) or "<%s>" % raw.strip("{} "))
    return out or [""]


def member_rows(src, t, members, base, kind):
    rows = []
    cls_base = [""]
    consts = dict(CONST_RE.findall(src.code))
    for a in t["ann_list"]:
        if a[0] == "RequestMapping":
            cls_base = mapping_paths(a[1], consts)
    for mem in members:
        for name, args, at, _end in mem["anns"]:
            if name in MAPPING and kind == "controller":
                methods = [MAPPING[name]] if MAPPING[name] else (
                    re.findall(r"RequestMethod\.(\w+)", (args or {}).get("method", "")) or ["ANY"])
                for b in cls_base:
                    for p in mapping_paths(args, consts):
                        for hm in methods:
                            rows.append(dict(base, id="%s:%s#%s %s %s" % (base["svc"], t["fqn"], mem["name"], hm, join_path(b, p)),
                                             kind="endpoint", name="%s#%s" % (t["name"], mem["name"]),
                                             fqn="%s#%s" % (t["fqn"], mem["name"]), line=src.line(at),
                                             http={"method": hm, "path": join_path(b, p)}))
            elif name in LISTENER_ANN:
                args = args or {}
                exprs = strings(args.get("topics", "")) + strings(args.get("value", "")) or strings(args.get("topicPattern", ""))
                for e in exprs or [None]:
                    row = dict(base, id="%s:%s#%s" % (base["svc"], t["fqn"], mem["name"]), kind="listener",
                               name="%s#%s" % (t["name"], mem["name"]), fqn="%s#%s" % (t["fqn"], mem["name"]),
                               line=src.line(at), topic=None)
                    if e is not None:
                        topic, prop = split_prop(e)
                        row["topic"] = topic
                        if prop:
                            row["topic_prop"] = prop
                            row["id"] += "@" + prop
                        else:
                            row["id"] += "@" + e
                    rows.append(row)
            elif name == "Bean" and ROUTER_RETURN_RE.search(mem["ret"]):
                rows.append(dict(base, id="%s:%s#%s" % (base["svc"], t["fqn"], mem["name"]), kind="router",
                                 name="%s#%s" % (t["name"], mem["name"]), fqn="%s#%s" % (t["fqn"], mem["name"]),
                                 line=src.line(at)))
    return rows


def producer_rows(src, t, inner, base):
    """KafkaTemplate-typed fields/params of t → one producer row per send call site (topic literal or null)."""
    body = src.skel[t["body"]:t["end"]]
    if not (set(re.findall(r"\b([A-Z]\w*)\b", body + t["ext"])) & KAFKA_PRODUCER_TYPES):
        return []
    fields = {m.group(2) for m in FIELD_TYPE_RE.finditer(src.skel[t["at"]:t["end"]]) if m.group(1) in KAFKA_PRODUCER_TYPES}
    rows = []
    for m in SEND_RE.finditer(src.skel, t["body"], t["end"]):
        if any(lo < m.start() < hi for lo, hi in inner) or m.group(1) not in fields:
            continue
        close = src.match(m.end() - 1, "(", ")")
        parts = split_top(src.code[m.end():close])
        first = parts[0].strip() if parts else ""
        lit = strings(first)
        topic = lit[0] if lit and first.startswith('"') else None
        row = dict(base, id="%s:%s!send@%d" % (base["svc"], t["fqn"], src.line(m.start())), kind="producer",
                   name="%s.%s" % (t["name"], m.group(2)), fqn=t["fqn"], line=src.line(m.start()), topic=topic)
        if topic is None and first:
            row["topic_expr"] = first[:80]
        rows.append(row)
    if not rows:
        at = t["line"]
        rows.append(dict(base, id="%s:%s!producer" % (base["svc"], t["fqn"]), kind="producer", name=t["name"],
                         fqn=t["fqn"], line=at, topic=None))
    return rows


def table_name(anns):
    for name, args, _a, _e in anns:
        if name in ("Table", "Entity", "Document") and args:
            v = strings(args.get("name", "")) or strings(args.get("value", ""))
            if v:
                return v[0]
    return None


def client_target(src, t):
    for name, args, _a, _e in t["ann_list"]:
        if name in ("FeignClient", "HttpExchange") and args:
            for key in ("url", "value", "name"):
                v = strings(args.get(key, ""))
                if v:
                    return v[0]
    for m in BASE_URL_RE.finditer(src.skel, t["body"], t["end"]):
        close = src.match(m.end() - 1, "(", ")")
        arg = src.code[m.end():close].strip()
        lit = strings(arg)
        if lit and arg.startswith('"'):
            return lit[0]
        return None  # a property expression: never guessed
    return None


# ---------------------------------------------------------------- migrations ----------------------------------
def extract_migration(rel, text, svc):
    name = rel.rsplit("/", 1)[-1]
    tables, line = [], 1
    clean = re.sub(r"--[^\n]*", lambda m: " " * len(m.group(0)), text)
    for m in CREATE_TABLE_RE.finditer(clean):
        tb = m.group(2).strip('"').split(".")[-1].strip('"')
        if not tables:
            line = clean.count("\n", 0, m.start()) + 1
        if tb not in tables:
            tables.append(tb)
    row = {"svc": svc, "file": rel, "id": "%s:migration:%s" % (svc, name), "kind": "migration", "name": name,
           "line": line}
    if tables:
        row["table"] = tables[0]
        row["tables"] = tables[:20]
    return [row]


def extract_file(rel, text, svc):
    if MIGRATION_RE.search(rel):
        return extract_migration(rel, text, svc)
    return extract_java(rel, text, svc)


def sort_rows(rows):
    return sorted(rows, key=lambda r: (r["file"], r["line"], r["id"]))


# ---------------------------------------------------------------- contracts (M6 plug point) -------------------
YML_URL_RE = re.compile(r"^\s*([\w.-]*(?:url|uri|base-url|baseUrl|host)[\w.-]*)\s*:\s*[\"']?\$\{([A-Z0-9_]+)(?::([^}]*))?\}", re.I)  # rule:yml-client-env
YML_DB_RE = re.compile(r"(?:r2dbc|jdbc):(?:pool:)?(?:postgresql|mysql|mariadb|sqlserver|oracle)[^\s\"']*?/([A-Za-z_][\w-]*)(?:[?\"'\s}]|$)")  # rule:yml-db
YML_TOPIC_RE = re.compile(r"^\s*([\w.-]*topic[\w.-]*)\s*:\s*[\"']?(?:\$\{[A-Z0-9_]+:)?([A-Za-z0-9_.\-]+)", re.I)  # rule:yml-topic
LIB_RE = re.compile(r"[\"'](io\.f8a\.summer:[\w.-]+)(?::[^\"']*)?[\"']")  # rule:summer-lib


def extract_contracts(rows, texts):
    """rows: all components; texts: {rel: text} of contract inputs (application*.yml, *.gradle, pom.xml)."""
    c = {"http_exposed": [], "http_clients": [], "kafka_consume": [], "kafka_produce": [], "db": [], "libs": [],
         "yml_topics": []}
    for r in rows:
        at = "%s:%d" % (r["file"], r["line"])
        if r["kind"] == "endpoint":
            c["http_exposed"].append({"method": r["http"]["method"], "path": r["http"]["path"], "handler_id": r["id"], "at": at})
        elif r["kind"] == "listener":
            c["kafka_consume"].append({"topic": r.get("topic"), "env": r.get("topic_prop"), "at": at})
        elif r["kind"] == "producer":
            c["kafka_produce"].append({"topic": r.get("topic"), "prefix": None, "at": at})
    for rel in sorted(texts):
        for i, ln in enumerate(texts[rel].splitlines(), 1):
            at = "%s:%d" % (rel, i)
            if rel.endswith((".yml", ".yaml")):
                m = YML_URL_RE.search(ln)
                if m:
                    c["http_clients"].append({"key": m.group(1), "env": m.group(2), "default_url": m.group(3), "at": at})
                for d in YML_DB_RE.findall(ln):
                    c["db"].append({"name": d, "at": at})
                m = YML_TOPIC_RE.search(ln)
                if m:
                    c["yml_topics"].append({"key": m.group(1), "topic": m.group(2), "at": at})
            else:
                for coord in LIB_RE.findall(ln):
                    c["libs"].append({"coord": coord, "at": at})
    return c
