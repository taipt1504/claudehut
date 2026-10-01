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
CONTRACT_RE = re.compile(r"(^|/)(src/main/resources/application[^/]*\.ya?ml|[^/]*\.gradle(\.kts)?|pom\.xml|gradle\.properties|gradle/[^/]+\.versions\.toml)$")
# Spring Boot auto-configuration registrations (a library's public surface; a service's own ones too)
AUTOCONF_RE = re.compile(r"(^|/)src/main/resources/META-INF/(spring/[^/]*AutoConfiguration\.imports|spring\.factories)$")
EXCLUDE_RE = re.compile(r"(^|/)(build|target|out|\.gradle|node_modules)/")


def excluded(path):
    """Build output dirs are excluded only BEFORE src/main/: a package named out/build/target (hexagonal
    adapter/out/…) is source."""
    i = path.find("src/main/")
    return bool(EXCLUDE_RE.search(path[:i] if i >= 0 else path))


def is_source(path):
    """A file whose content produces components (java under src/main, Flyway migrations)."""
    return not excluded(path) and bool(JAVA_RE.search(path) or MIGRATION_RE.search(path) or AUTOCONF_RE.search(path))


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
# Library surface (a repo detected as a multi-module publisher, see library_info): checked only there, so a
# service's public interfaces / annotations never flood its index. "properties" wins over CLASS_RULES' config.
LIB_CLASS_RULES = {}
LIB_CLASS_RULES["properties"] = lambda t: "ConfigurationProperties" in t["ann"]  # rule:lib-properties
LIB_CLASS_RULES["annotation"] = lambda t: t["kw"] == "@interface" and t["public"]  # rule:lib-annotation
LIB_CLASS_RULES["spi"] = lambda t: t["kw"] == "interface" and t["public"]  # rule:lib-spi
LIB_MEMBER_RULES = {}
LIB_MEMBER_RULES["bean"] = "Bean"  # rule:lib-bean
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
# reactor-kafka receiver site: KafkaReceiver.create(…), ReceiverOptions….subscription/assignment(…), or a call to a
# receiver factory (KafkaConfigUtil.createReactiveDltReceiver(kafkaProperties, listenerProperties, …)).
RECEIVER_RE = re.compile(r"\bKafkaReceiver\s*\.\s*create\s*\(|\.\s*(?:subscription|assignment)\s*\(|\.\s*(create\w*Receiver)\s*\(")  # rule:reactor-receiver
TOPIC_GETTER_RE = re.compile(r"\b([a-z]\w*)((?:\s*\.\s*\w+\s*\(\s*\))*?)\s*\.\s*((?:get)?[Tt]opics?(?:Name)?)\s*\(\s*\)")
VALUE_TOPIC_RE = re.compile(r'@Value\s*\(\s*"\$\{([\w.\-\[\]]*topic[\w.\-\[\]]*)(?::([^}"]*))?\}"', re.I)
BASE_URL_RE = re.compile(r"\.\s*(baseUrl|rootUri)\s*\(")  # rule:client-base-url
CREATE_TABLE_RE = re.compile(r"\b(create\s+table(?:\s+if\s+not\s+exists)?|alter\s+table(?:\s+if\s+exists)?(?:\s+only)?)\s+([\"\w.]+)", re.I)  # rule:flyway-table

KIND_ORDER = ["controller", "endpoint", "router", "service", "listener", "producer", "client", "repository",
              "entity", "config", "migration", "component", "module", "autoconfig", "properties", "annotation", "spi",
              "bean"]

MODIFIERS = r"(?:(?:public|protected|private|static|final|abstract|sealed|non-sealed|default|synchronized|strictfp|native|transient|volatile)\s+)*"
TYPE_DECL_RE = re.compile(r"(?<![\w.@])(class|@?interface|enum|record)\s+([A-Za-z_$][\w$]*)")
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
def class_kind(t, lib):
    """CLASS_RULES first-match; in a library repo @ConfigurationProperties is `properties` and an otherwise
    unclassified public interface / @interface is `spi` / `annotation`. A service's @interface stays unindexed."""
    if lib and LIB_CLASS_RULES.get("properties", lambda _t: False)(t):
        return "properties"
    if t["kw"] == "@interface" and not lib:
        return None
    k = next((k for k, pred in CLASS_RULES if pred(t)), None)
    if k or not lib:
        return k
    return next((k for k, pred in LIB_CLASS_RULES.items() if k != "properties" and pred(t)), None)


def camel_kebab(name):
    return re.sub(r"(?<=[a-z0-9])([A-Z])", r"-\1", name).lower()


PROP_FIELD_RE = re.compile(r"\b([A-Za-z][\w.]*)\s*(<[^;{}()=]*?>)?\s*(?:\[\s*\])?\s+([a-z]\w*)\s*[;=]")


def prop_keys(src, types, t, prefix, depth=0):
    """@ConfigurationProperties keys: non-static fields (or record components) of t in kebab case; a field whose type is
    a nested type of the same file expands one more level (Map<String, X> → key.*.sub)."""
    out = []
    if t["kw"] == "record":
        head = src.code[src.skel.find("(", t["at"]) + 1:t["body"]]
        comps = [re.findall(r"(\w+)\s*$", p.strip()) for p in split_top(head.rsplit(")", 1)[0])]
        return ["%s.%s" % (prefix, camel_kebab(c[0])) for c in comps if c]
    inner = [(o["body"], o["end"]) for o in types if t["body"] < o["at"] < t["end"]]
    by = {o["name"]: o for o in types}
    for m in PROP_FIELD_RE.finditer(src.skel, t["body"], t["end"]):
        p = m.start(3)
        if src.depth(p) != t["depth"] or src.pdepth(p) != 0 or any(lo < p < hi for lo, hi in inner):
            continue
        if re.search(r"\bstatic\b", src.skel[src.stmt_start(m.start()):m.start()]):
            continue
        key = "%s.%s" % (prefix, camel_kebab(m.group(3)))
        ty, args = m.group(1), re.findall(r"[A-Z][\w.]*", m.group(2) or "")
        if ty in ("return", "throw", "new", "else", "case", "yield"):
            continue
        nested = by.get(ty) or (by.get(args[-1]) if ty in ("Map", "List", "Set") and args else None)
        if nested is not None and nested is not t and depth < 2 and nested["kw"] in ("class", "record"):
            sub = key + (".*" if ty == "Map" else "[*]" if ty in ("List", "Set") else "")
            out += prop_keys(src, types, nested, sub, depth + 1) or [sub]
        else:
            out.append(key)
    return out


def extract_java(rel, text, svc, lib=None):
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
        mods = src.skel[(anns[-1][3] if anns else src.stmt_start(t["at"])):t["at"]]
        outer_iface = any(o["body"] < t["at"] < o["end"] and o["kw"] in ("interface", "@interface") for o in types)
        t["public"] = bool(re.search(r"\bpublic\b", mods)) or outer_iface
        inner = [(o["body"], o["end"]) for o in types if t["body"] < o["at"] < t["end"]]
        body_code = src.skel[t["body"]:t["end"]]
        t["uses"] = set(re.findall(r"\b([A-Z]\w*)\b", body_code + " " + t["ext"])) & (HTTP_CLIENT_TYPES | KAFKA_PRODUCER_TYPES)
        members = member_decls(src, t, inner)
        kind = class_kind(t, lib)
        purpose = doc_before(src, at)
        base = {"svc": svc, "file": rel}
        if lib and lib.get("module_of"):
            base["module"] = lib["module_of"]
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
            if kind in ("client", "config") and not row.get("target"):
                row.update(client_target_ref(src, t))
            if kind in ("config", "properties"):
                pre = props_prefix(t["ann_list"])
                if pre:
                    row["props_prefix"] = pre
                    if kind == "properties":
                        row["props"] = prop_keys(src, types, t, pre)[:40]
            rows.append(row)
        rows.extend(member_rows(src, t, members, base, kind, bool(lib)))
        rows.extend(producer_rows(src, t, inner, base))
        rows.extend(receiver_rows(src, t, inner, base))
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


def member_rows(src, t, members, base, kind, lib=False):
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
            elif lib and name == LIB_MEMBER_RULES.get("bean"):  # a library's @Bean factory (what a consumer gets)
                ret = re.sub(r"\b(public|protected|private|static|final|synchronized)\b", " ", mem["ret"])
                ret = re.sub(r"<[^<>]*>", "", re.sub(r"<[^<>]*>", "", ret)).split()
                row = dict(base, id="%s:%s#%s" % (base["svc"], t["fqn"], mem["name"]), kind="bean",
                           name="%s#%s" % (t["name"], mem["name"]), fqn="%s#%s" % (t["fqn"], mem["name"]),
                           line=src.line(at), annotations=sorted({a[0] for a in mem["anns"]}))
                if len(ret) >= 2:  # "... Type name" — the return type precedes the method name
                    row["type"] = ret[-2]
                rows.append(row)
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


def receiver_rows(src, t, inner, base):
    """reactor-kafka consumers → one listener row per receiver call site (distinct topic refs). The topic is never
    guessed here: topic_ref = [{types, path}] of the class's own FIELDS — a props field passed to the call (path
    [topic]) or a props.getTopic() chain — resolved cross-file by receiver_topic_prop; else an @Value topic key
    (topic_prop). A factory class that only sees parameters (KafkaConfigUtil itself) emits nothing."""
    code = src.code[t["at"]:t["end"]]
    fields = {}
    for m in re.finditer(r"\b([A-Z]\w*(?:\.[A-Z]\w*)*)\s*(?:<[^;{}()]*?>)?\s+(\w+)\s*[;=]", src.skel[t["body"]:t["end"]]):
        p = t["body"] + m.start(2)
        if src.depth(p) == t["depth"] and src.pdepth(p) == 0 and not any(lo < p < hi for lo, hi in inner):
            fields.setdefault(m.group(2), m.group(1))
    def refs_in(lo, hi):
        out = []
        for m in TOPIC_GETTER_RE.finditer(src.skel, lo, hi):
            if fields.get(m.group(1)) and not any(a < m.start() < b for a, b in inner):
                out.append({"types": [fields[m.group(1)]], "path": re.findall(r"(\w+)\s*\(", m.group(2)) + [m.group(3)]})
        return out
    vt = VALUE_TOPIC_RE.search(code)
    rows, seen = [], set()
    for m in RECEIVER_RE.finditer(src.skel, t["body"], t["end"]):
        if any(lo < m.start() < hi for lo, hi in inner):
            continue
        if not m.group(1) and "KafkaReceiver" not in code and "ReceiverOptions" not in code:
            continue  # .subscription( / .assignment( of some other API
        close = src.match(m.end() - 1, "(", ")")
        refs = refs_in(m.end(), close)
        refs += [{"types": [fields[a.strip()]], "path": ["topic"]} for a in split_top(src.code[m.end():close])
                 if fields.get(a.strip())]
        refs = refs or refs_in(t["body"], t["end"])
        key = repr(refs) if refs else (vt.group(1) if vt else None)
        if not key or key in seen:
            continue
        seen.add(key)
        ln = src.line(m.start())
        row = dict(base, id="%s:%s!receiver@%d" % (base["svc"], t["fqn"], ln), kind="listener",
                   name="%s#%s" % (t["name"], m.group(1) or "receiver"), fqn=t["fqn"], line=ln, topic=None)
        if refs:
            row["topic_ref"] = refs
        else:
            row["topic_prop"] = vt.group(1)
            row["topic"] = vt.group(2) or None
        rows.append(row)
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


# Client target resolution (M6): a base URL taken from a property is never guessed in the row; the row records
# where the property comes from, and extract_contracts resolves it against application*.yml.
#   target_prop  a dotted key from @Value("${key}") on a url/uri/host-like key inside the class
#   target_ref   {types:[declared type names of the receiver], path:[getter names]} for props.getA().getBaseUrl()
VALUE_URL_RE = re.compile(r'@Value\s*\(\s*"\$\{([\w.\-\[\]]*(?:url|uri|host)[\w.\-\[\]]*)(?::[^}"]*)?\}"', re.I)
GETTER_CHAIN_RE = re.compile(r"\b([a-z]\w*)((?:\s*\.\s*\w+\s*\(\s*\))*?)\s*\.\s*((?:get)?(?:BaseUrl|baseUrl|Url|url|Uri|uri|Host|host))\s*\(\s*\)")


def props_prefix(anns):
    for name, args, _a, _e in anns:
        if name == "ConfigurationProperties" and args:
            v = strings(args.get("prefix", "")) or strings(args.get("value", ""))
            if v:
                return v[0]
    return None


def client_target_ref(src, t):
    body = src.code[t["at"]:t["end"]]
    m = VALUE_URL_RE.search(body)
    if m:
        return {"target_prop": m.group(1)}
    for m in GETTER_CHAIN_RE.finditer(src.skel, t["body"], t["end"]):
        recv = m.group(1)
        if recv in ("this", "super", "builder", "options", "webClient", "restTemplate"):
            continue
        path = re.findall(r"(\w+)\s*\(", m.group(2)) + [m.group(3)]
        types = []
        for tm in re.finditer(r"\b([A-Z]\w*(?:\.[A-Z]\w*)*)\s*(?:<[^;{}()]*?>)?\s+%s\b" % re.escape(recv), body):
            if tm.group(1) not in types and tm.group(1) != "String":
                types.append(tm.group(1))
        if types:
            return {"target_ref": {"types": types, "path": path}}
    return {}


def relax(key):
    """Spring relaxed binding: baseUrl, base-url, base_url and BASE_URL are one key."""
    return re.sub(r"[-_]", "", (key or "").lower())


def getter_key(name):
    n = name[3:] if re.match(r"get[A-Z]", name) else name
    return relax(n)


YML_KEY_RE = re.compile(r"^(\s*)(?:\"([^\"]+)\"|'([^']+)'|([^\s:#][^:#]*?))\s*:(?:\s+(.*?))?\s*$")
YML_REF_RE = re.compile(r"\$\{([A-Za-z0-9_.\-]+)(?::([^}]*))?\}")


def yml_flat(text):
    """application*.yml → [{prop, line, value}] with dotted keys (block mappings only; list items and flow
    collections are skipped, never guessed). value is the raw scalar, quotes and trailing comment removed."""
    out, stack, block = [], [], None
    for i, ln in enumerate(text.splitlines(), 1):
        if ln.strip() in ("---", "..."):
            stack, block = [], None
            continue
        if not ln.strip():
            continue
        ind = len(ln.expandtabs()) - len(ln.expandtabs().lstrip())
        if block is not None:
            if ind > block:
                continue  # block scalar body
            block = None
        if ln.lstrip().startswith("#") or ln.lstrip().startswith("- ") or ln.strip() == "-":
            continue
        m = YML_KEY_RE.match(ln)
        if not m:
            continue
        key = (m.group(2) or m.group(3) or m.group(4) or "").strip()
        while stack and stack[-1][0] >= ind:
            stack.pop()
        prop = ".".join([k for _, k in stack] + [key])
        val = (m.group(5) or "").strip()
        if val and val[0] not in "\"'":
            val = re.sub(r"\s+#.*$", "", val)
        if val[:1] in "\"'" and val[-1:] == val[:1] and len(val) >= 2:
            val = val[1:-1]
        if not val:
            stack.append((ind, key))
        elif re.fullmatch(r"[|>][+-]?\d*", val):
            block = ind
        else:
            out.append({"prop": prop, "line": i, "value": val})
    return out


def yml_lookup(flat, key):
    """flat entries of every yml file ({rel: [...]}) → first (rel, entry) whose relaxed prop equals key."""
    want = relax(key)
    for rel in sorted(flat, key=lambda r: (not r.endswith(("application.yml", "application.yaml")), r)):
        for e in flat[rel]:
            if relax(e["prop"]) == want:
                return rel, e
    return None, None


def resolve_client_targets(rows, flat):
    """Client/config rows with target_prop / target_ref → [{client, at, prop, env, default_url, yml_at}]."""
    prefixes = {}
    for r in rows:
        if r.get("props_prefix"):
            prefixes.setdefault(r["name"], r["props_prefix"])
    out = []
    for r in rows:
        keys = []
        if r.get("target_prop"):
            keys.append(r["target_prop"])
        ref = r.get("target_ref") or {}
        for ty in ref.get("types") or []:
            parts = ty.split(".")
            pre = prefixes.get(parts[0])
            if pre:
                keys.append(".".join([pre] + [relax(p) for p in parts[1:]] + [getter_key(p) for p in ref.get("path") or []]))
        for k in keys:
            rel, e = yml_lookup(flat, k)
            if not e:
                continue
            m = YML_REF_RE.search(e["value"])
            env, dflt = (m.group(1), m.group(2)) if m and m.group(1).upper() == m.group(1) else (None, None if m else e["value"])
            out.append({"client": r["name"], "at": "%s:%d" % (r["file"], r["line"]), "prop": e["prop"], "env": env,
                        "default_url": dflt, "yml_at": "%s:%d" % (rel, e["line"])})
            break
    return out


def receiver_topic_prop(row, rows, flat):
    """A receiver listener row's topic_ref → the application*.yml property it binds to (None when unresolved): the
    field type's @ConfigurationProperties prefix + the getter path, e.g. kafka.consumer.link-account.topic."""
    prefixes = {}
    for r in rows:
        if r.get("props_prefix"):
            prefixes.setdefault(r["name"], r["props_prefix"])
    for ref in row.get("topic_ref") or []:
        for ty in ref.get("types") or []:
            parts = ty.split(".")
            pre = prefixes.get(parts[0])
            if pre:
                rel, e = yml_lookup(flat, ".".join([pre] + [relax(p) for p in parts[1:]] + [getter_key(p) for p in ref.get("path") or []]))
                if e:
                    return e["prop"]
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


# ---------------------------------------------------------------- library surface ------------------------------
AUTOCONF_LINE = {}
AUTOCONF_LINE["imports"] = re.compile(r"^\s*([A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)+)\s*(?:#.*)?$")  # rule:autoconfig-imports
AUTOCONF_LINE["factories"] = re.compile(r"(?:^|,)\s*([A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)+)\s*(?=,|$)")  # rule:spring-factories
FACTORIES_KEY = "org.springframework.boot.autoconfigure.EnableAutoConfiguration"


def extract_autoconf(rel, text, svc, lib=None):
    """META-INF/spring/…AutoConfiguration.imports (one class per line) or spring.factories (the EnableAutoConfiguration
    key, backslash continuations) → one autoconfig row per registered class, at its own line."""
    rows, base = [], {"svc": svc, "file": rel}
    if lib and lib.get("module_of"):
        base["module"] = lib["module_of"]
    imports = rel.endswith(".imports")
    rule = AUTOCONF_LINE.get("imports" if imports else "factories")
    if rule is None:
        return rows
    on = cont = False
    for i, ln in enumerate(text.splitlines(), 1):
        if not cont and ln.lstrip().startswith(("#", "!")):
            continue
        if imports:
            found = [m.group(1) for m in [rule.match(ln)] if m]
        else:
            val = ln
            if not cont:
                key, _eq, val = ln.partition("=")
                on = bool(_eq) and key.strip() == FACTORIES_KEY
            cont = ln.rstrip().endswith("\\")
            found = [m.group(1) for m in rule.finditer(val.rstrip("\\ \t"))] if on else []
        for fqn in found:
            rows.append(dict(base, id="%s:%s!autoconfig%s" % (svc, fqn, "" if imports else "@factories"),
                             kind="autoconfig", name=fqn.rsplit(".", 1)[-1], fqn=fqn, line=i))
    return rows


LIB_DETECT = {}
LIB_DETECT["publish"] = re.compile(r"maven-publish|java-platform|\bpublishing\s*\{")  # rule:lib-module
BOOT_APP_RE = re.compile(r"""(?:\bid\s*\(?\s*|apply\s*\(?\s*plugin\s*[:=]\s*)['"]org\.springframework\.boot['"]""")
GROUP_RE = re.compile(r"""(?m)^\s*group\s*=?\s*['"]?([\w.\-]+)['"]?\s*$""")
VERSION_LINE_RE = re.compile(r"""(?m)^\s*version\s*=\s*(['"]?)([\w.\-+]+)\1\s*$""")
SETTINGS = ("settings.gradle", "settings.gradle.kts")


def library_info(files, read):
    """A repo that publishes ≥2 Gradle modules (maven-publish / java-platform, a group, no Spring Boot application
    plugin) → {group, root, version, modules:[{artifact, dir, build, bom?, version?}]}; anything else → None.
    Module names follow settings.gradle: explicit include(…) paths, else every sub-directory build file (the dynamic
    fileTree style); a root-name prefix (`'summer'.concat('-'…)`, "${rootProject.name}-…") is applied."""
    pub = LIB_DETECT.get("publish")
    st = next((f for f in SETTINGS if f in files), None)
    if pub is None or st is None:
        return None
    stext = lex(read(st) or "")[0]
    m = re.search(r"""rootProject\.name\s*=\s*['"]([^'"]+)['"]""", stext)
    root = m.group(1) if m else None
    builds = [f for f in files if re.search(r"(^|/)[^/]*\.gradle(\.kts)?$", f) and "/" in f
              and not re.match(r"(buildSrc|gradle)/", f) and "/src/" not in "/" + f and not f.endswith(SETTINGS)]
    texts = {f: lex(read(f) or "")[0] for f in builds + [x for x in ("build.gradle", "build.gradle.kts") if x in files]}
    if not any(pub.search(t) for t in texts.values()) or any(BOOT_APP_RE.search(t) for t in texts.values()):
        return None
    props = read("gradle.properties") if "gradle.properties" in files else ""
    group = None
    for t in [props or ""] + [texts.get(x, "") for x in ("build.gradle", "build.gradle.kts")]:
        g = GROUP_RE.search(t)
        if g:
            group = g.group(1)
            break
    if not group:
        return None
    pvars = dict(re.findall(r"(?m)^\s*([\w.\-]+)\s*=\s*(\S+)\s*$", props or ""))
    incl = []
    for im in re.finditer(r"""\binclude\s*\(?((?:\s*['"][^'"]+['"]\s*,?)+)""", stext):
        incl += [x for x in re.findall(r"""['"]([^'"]+)['"]""", im.group(1)) if re.fullmatch(r":?[\w.\-]+(:[\w.\-]+)*", x)]
    dirs = {}
    for f in builds:
        dirs.setdefault(f.rsplit("/", 1)[0], f)
    pdir = dict(re.findall(r"""project\(\s*['"]:?([\w:.\-]+)['"]\s*\)\.projectDir\s*=\s*(?:new\s+File\([^,]+,\s*|file\(\s*)['"]([^'"]+)['"]""", stext))
    pname = dict(re.findall(r"""project\(\s*['"]:?([\w:.\-]+)['"]\s*\)\.name\s*=\s*['"]([^'"]+)['"]""", stext))
    prefix = ""
    if root and re.search(r"""['"]%s['"]\s*\.concat\(|['"]%s-|\$\{?rootProject\.name\}?-""" % (re.escape(root), re.escape(root)), stext):
        prefix = root + "-"
    mods = []
    paths = [p.lstrip(":") for p in incl] if incl else sorted(dirs)
    for p in paths:
        d = pdir.get(p) or (p.replace(":", "/") if incl else p)
        build = dirs.get(d)
        if incl and not build:
            continue
        leaf = (p.split(":")[-1] if incl else d.rsplit("/", 1)[-1])
        art = pname.get(p) or (leaf if leaf.startswith(prefix) else prefix + leaf)
        mod = {"artifact": art, "dir": d, "build": build}
        bt = texts.get(build, "")
        if "java-platform" in bt:
            mod["bom"] = True
        vm = re.search(r"(?m)^\s*version\s*=\s*(['\"]?)([\w.\-+]+)\1\s*$", bt)
        if vm:
            mod["version"] = vm.group(2) if vm.group(1) else pvars.get(vm.group(2), None)
            if not mod["version"]:
                mod.pop("version")
        mods.append(mod)
    if len(mods) < 2:
        return None
    vm = VERSION_LINE_RE.search(props or "") or VERSION_LINE_RE.search(texts.get("build.gradle", ""))
    return {"group": group, "root": root, "version": vm.group(2) if vm else None,
            "modules": sorted(mods, key=lambda x: x["dir"])}


def module_of(lib, rel):
    """The artifact of the deepest library module dir containing rel (None outside every module)."""
    best = None
    for m in (lib or {}).get("modules", []):
        if rel.startswith(m["dir"] + "/") and (best is None or len(m["dir"]) > len(best["dir"])):
            best = m
    return best["artifact"] if best else None


def library_rows(lib, svc):
    """One `module` row per published module (at its build file)."""
    rows = []
    for m in (lib or {}).get("modules", []):
        r = {"svc": svc, "file": m["build"], "line": 1, "id": "%s:module:%s" % (svc, m["artifact"]), "kind": "module",
             "name": m["artifact"], "fqn": "%s:%s" % (lib["group"], m["artifact"]), "module": m["artifact"]}
        if m.get("bom"):
            r["tags"] = ["bom"]
        rows.append(r)
    return rows


def extract_file(rel, text, svc, lib=None):
    """lib: library_info() of the repo (None for a service); its module of rel is added as row['module']."""
    if lib:
        lib = dict(lib, module_of=module_of(lib, rel))
    if MIGRATION_RE.search(rel):
        return extract_migration(rel, text, svc)
    if AUTOCONF_RE.search(rel):
        return extract_autoconf(rel, text, svc, lib)
    return extract_java(rel, text, svc, lib)


def sort_rows(rows):
    return sorted(rows, key=lambda r: (r["file"], r["line"], r["id"]))


# ---------------------------------------------------------------- contracts (M6 plug point) -------------------
YML_URL_RE = re.compile(r"^\s*([\w.-]*(?:url|uri|base-url|baseUrl|host)[\w.-]*)\s*:\s*[\"']?\$\{([A-Z0-9_]+)(?::([^}]*))?\}", re.I)  # rule:yml-client-env
YML_DB_RE = re.compile(r"(?:r2dbc|jdbc):(?:pool:)?(?:postgresql|mysql|mariadb|sqlserver|oracle)[^\s\"']*?/([A-Za-z_][\w-]*)(?:[?\"'\s}]|$)")  # rule:yml-db
YML_TOPIC_RE = re.compile(r"^\s*([\w.-]*topic[\w.-]*)\s*:\s*[\"']?(?:\$\{[A-Z0-9_]+:)?([A-Za-z0-9_.\-]+)", re.I)  # rule:yml-topic
# Library dependencies (any group:artifact[:version]; the hub decides which group a registered library owns).
DEP_RULES = {}
DEP_RULES["string"] = re.compile(r"""(['"])([A-Za-z][\w\-]*(?:\.[\w\-]+)+):([A-Za-z0-9][\w.\-]*)(?::([^'"@\s]+))?(?:@\w+)?\1""")  # rule:lib-dep
DEP_RULES["map"] = re.compile(r"""\bgroup\s*[:=]\s*['"]([\w.\-]+)['"]\s*,\s*name\s*[:=]\s*['"]([\w.\-]+)['"](?:\s*,\s*version\s*[:=]\s*['"]([^'"]+)['"])?""")  # rule:lib-dep-map
DEP_RULES["catalog"] = re.compile(r"\b([a-z]\w*)\.((?:[A-Za-z]\w*)(?:\.[A-Za-z]\w*)*)")  # rule:catalog-dep
DEP_RULES["platform"] = re.compile(r"\b(?:platform|enforcedPlatform|mavenBom)\b")  # rule:bom-platform
VERSION_RULES = {}
VERSION_RULES["property"] = re.compile(r"(?m)^\s*([A-Za-z_][\w.\-]*)\s*[=:]\s*([\w.\-+]+)\s*$")  # rule:version-prop
VERSION_RULES["ext"] = re.compile(r"""(?m)(?:^|[\s{;.])(?:ext\.|def\s+|val\s+|var\s+|extra\[\s*["'])?([A-Za-z_]\w*)(?:["']\s*\])?\s*=\s*['"]([\w.\-+]+)['"]""")  # rule:version-ext
VERSION_RULES["catalog-ref"] = re.compile(r'\bversion\.ref\s*=\s*"([^"]+)"|\bversion\s*=\s*\{\s*ref\s*=\s*"([^"]+)"')  # rule:catalog-version-ref
VAR_REF_RE = re.compile(r"""\$\{?\s*(?:project\.|rootProject\.|ext\.|property\(\s*['"])?([A-Za-z_]\w*)""")


def catalog(rel, text):
    """gradle/<name>.versions.toml → {accessor-key: {coord, version?, at_def}} (accessor-key: the alias lower-cased
    without - _ . so libs.summer.rest and libs.summerRest both find it). A regex reader: [versions] and
    [libraries] with string or inline-table values."""
    name = rel.rsplit("/", 1)[-1].split(".")[0]
    vers, libs, sec = {}, {}, None
    for i, ln in enumerate(text.splitlines(), 1):
        t = ln.split("#", 1)[0].strip()
        m = re.match(r"^\[([\w.\-]+)\]$", t)
        if m:
            sec = m.group(1)
            continue
        m = re.match(r"""^([\w.\-]+|"[^"]+")\s*=\s*(.+)$""", t)
        if not m:
            continue
        key, val = m.group(1).strip('"'), m.group(2).strip()
        if sec == "versions":
            v = re.match(r'^"([^"]+)"', val)
            if v:
                vers[key] = v.group(1)
        elif sec == "libraries":
            ent = {"at_def": "%s:%d" % (rel, i)}
            v = re.match(r'^"([^":]+):([^":]+)(?::([^"]+))?"$', val)
            if v:
                ent.update(coord="%s:%s" % (v.group(1), v.group(2)), version=v.group(3))
            else:
                mod = re.search(r'\bmodule\s*=\s*"([^":]+):([^"]+)"', val)
                g, a = re.search(r'\bgroup\s*=\s*"([^"]+)"', val), re.search(r'\bname\s*=\s*"([^"]+)"', val)
                if mod:
                    ent["coord"] = "%s:%s" % (mod.group(1), mod.group(2))
                elif g and a:
                    ent["coord"] = "%s:%s" % (g.group(1), a.group(1))
                else:
                    continue
                lit = re.search(r'\bversion\s*=\s*"([^"]+)"', val)
                ref = VERSION_RULES.get("catalog-ref")
                rm = ref.search(val) if ref else None
                if lit:
                    ent["version"] = lit.group(1)
                elif rm:
                    r = rm.group(1) or rm.group(2)
                    ent["version"] = vers.get(r)
                    ent["version_expr"] = "versions." + r
            libs[re.sub(r"[-_.]", "", key.lower())] = ent
    return name, libs


def dep_vars(texts):
    """Version variables: gradle.properties (root first) and ext / def / val assignments in *.gradle(.kts)."""
    out = {}
    for rel in sorted(texts, key=lambda r: (r.count("/"), r)):
        rule = VERSION_RULES.get("property") if rel.endswith("gradle.properties") else \
            VERSION_RULES.get("ext") if re.search(r"\.gradle(\.kts)?$", rel) else None
        if rule:
            for k, v in rule.findall(lex(texts[rel])[0] if rel.endswith((".gradle", ".kts")) else texts[rel]):
                out.setdefault(k, v)
    return out


def resolve_version(expr, dvars):
    """'1.2.3' → ('1.2.3', 'explicit'); '${summerVersion}' / '$v' → (value, 'property'); unresolved → (None, None)."""
    if not expr:
        return None, None
    if "$" not in expr:
        return expr, "explicit"
    out = VAR_REF_RE.sub(lambda m: dvars.get(m.group(1), "\0"), expr)
    out = re.sub(r"""['"]\s*\)|\}""", "", out)
    return (out, "property") if "\0" not in out and re.fullmatch(r"[\w.\-+]+", out) else (None, None)


def extract_deps(texts):
    """*.gradle(.kts) (+ gradle.properties, gradle/*.versions.toml) → [{coord, group, artifact, at, config, scope,
    version?, version_src?, version_expr?, platform?, at_def?}]: one entry per dependency declaration line."""
    dvars = dep_vars(texts)
    cats = dict(catalog(rel, texts[rel]) for rel in sorted(texts) if rel.endswith(".versions.toml"))
    out, seen = [], set()
    plat = DEP_RULES.get("platform")
    for rel in sorted(texts):
        if not re.search(r"\.gradle(\.kts)?$", rel):
            continue
        for i, ln in enumerate(lex(texts[rel])[0].splitlines(), 1):
            if not ln.strip():
                continue
            cm = re.match(r"\s*([A-Za-z]\w*)\s*[\s(]", ln)
            base = {"at": "%s:%d" % (rel, i), "config": cm.group(1) if cm else None}
            if plat and plat.search(ln):
                base["platform"] = True
            found = []
            if DEP_RULES.get("string"):
                found += [(m.group(2), m.group(3), m.group(4), None) for m in DEP_RULES["string"].finditer(ln)]
            if DEP_RULES.get("map"):
                found += [(m.group(1), m.group(2), m.group(3), None) for m in DEP_RULES["map"].finditer(ln)]
            if DEP_RULES.get("catalog"):
                for m in DEP_RULES["catalog"].finditer(ln):
                    acc = re.sub(r"\.get$", "", m.group(2))
                    if m.group(1) not in cats or acc.split(".")[0] in ("versions", "plugins", "bundles"):
                        continue
                    ent = cats[m.group(1)].get(re.sub(r"[-_.]", "", acc.lower()))
                    if ent:
                        g, a = ent["coord"].split(":", 1)
                        found.append((g, a, None, ent))
            for g, a, v, ent in found:
                if (rel, i, g, a) in seen:
                    continue
                seen.add((rel, i, g, a))
                e = dict(base, coord="%s:%s" % (g, a), group=g, artifact=a)
                e["scope"] = "test" if (e["config"] or "").startswith("test") else "main"
                if ent:
                    e["at_def"] = ent["at_def"]
                    if ent.get("version"):
                        e.update(version=ent["version"], version_src="catalog")
                    elif ent.get("version_expr"):
                        e["version_expr"] = ent["version_expr"]
                elif v:
                    ver, src = resolve_version(v, dvars)
                    if ver:
                        e.update(version=ver, version_src=src)
                    else:
                        e["version_expr"] = v[:60]
                out.append({k: x for k, x in e.items() if x is not None})
    return out


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
    flat = {rel: yml_flat(texts[rel]) for rel in texts if rel.endswith((".yml", ".yaml"))}
    for r, kc in zip([r for r in rows if r["kind"] == "listener"], c["kafka_consume"]):
        prop = receiver_topic_prop(r, rows, flat) if r.get("topic_ref") else None
        if prop:  # reactor-kafka: the bound yml value (${ENV:default} → default)
            _rel, e = yml_lookup(flat, prop)
            m = YML_REF_RE.search(e["value"])
            kc.update(topic=(m.group(2) if m else e["value"]) or None, env=prop)
    props = {rel: {e["line"]: e["prop"] for e in ents} for rel, ents in flat.items()}
    c["client_targets"] = resolve_client_targets(rows, flat)
    for rel in sorted(texts):
        for i, ln in enumerate(texts[rel].splitlines(), 1):
            at = "%s:%d" % (rel, i)
            if rel.endswith((".yml", ".yaml")):
                m = YML_URL_RE.search(ln)
                if m:
                    hc = {"key": m.group(1), "env": m.group(2), "default_url": m.group(3), "at": at}
                    if props[rel].get(i):
                        hc["prop"] = props[rel][i]
                    c["http_clients"].append(hc)
                for d in YML_DB_RE.findall(ln):
                    c["db"].append({"name": d, "at": at})
                m = YML_TOPIC_RE.search(ln)
                if m:
                    c["yml_topics"].append({"key": m.group(1), "topic": m.group(2), "at": at})
    c["libs"] = extract_deps(texts)
    return c
