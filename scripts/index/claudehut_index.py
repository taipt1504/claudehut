"""claudehut_index.py — the `claudehut-index` CLI (07-index-memory.md §5–§7, ADR-IDX-1/2/5/7).

Read commands (agents call these): status, brief, find, svc, links. They never write a file and never change an
mtime: every git call runs with GIT_OPTIONAL_LOCKS=0, so `git status` does not refresh .git/index. The only
side effect a read may have is to start a detached `update` when the index is stale (brief/svc, §7);
CLAUDEHUT_INDEX_NO_SPAWN=1 turns that off.

Write commands (hooks, git hooks, init, merge-learnings call these): update, memory, install-git-hooks,
uninstall-git-hooks. `update` takes a mkdir lock (index/.lock, stale after 120 s), writes data files as
tmp + rename and meta.json LAST, so a failure leaves the index "stale", never "falsely fresh".

Errors: exit 0 with one line (`index: error — …`). Output is byte-bounded.

Data (the shared contract):
  <plane>/index/meta.json        {schema:1, indexed_commit, indexed_at, tool_version, counts, …}
  <plane>/index/components.jsonl one component per line (see extract.py)
  <plane>/index/files.json       {schema:1, files:{path:sha1}, dirty:[path]} — incremental-update state, kept out of
                                 meta.json so the hooks' head-only read of meta.json stays cheap
  <plane>/index/contracts.json   exposed/consumed contracts — the M6 hub-sync input
  <plane>/topology.json          {schema:1, mode, hub, language, shared, git_hooks, service?} (init writes it)
Hub (M6, hub.py): `svc <other>`, `find --svc S`, `links` read <hub>/.claude/claudehut/hub (topology.hub,
CLAUDEHUT_HUB or --hub); without a hub they answer "hub not configured". `update --hub-sync`, `hub-sync` and
`hub-scan` write only inside the hub.
"""
import fnmatch
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
import hub  # noqa: E402
from memory import resolve_language  # noqa: E402

TOOL_VERSION = "0.12.2-idx5"  # idx5: library surface + per-module lib deps; idx4: reactor-kafka receivers; idx3: client targets
SCHEMA = 1
LOCK_STALE_S = 120
FULL_RATIO = 0.30
HOOKS = ("post-merge", "post-rewrite", "post-checkout")
MARK_START = "# >>> claudehut-index >>>"
MARK_END = "# <<< claudehut-index <<<"
KIND_W = {k: i for i, k in enumerate(extract.KIND_ORDER)}
STOP = set("the and for with from into that this then when what which have has not are was use using add fix "
           "update new get set all any via per task file code java class method test tests src main".split())

MSG = {
    "en": {"fresh": "fresh", "stale": "stale: %s commit(s) behind — updating in background",
           "stale_noupd": "stale: %s commit(s) behind", "stale_scan": "stale: %s commit(s) behind — refresh: hub-scan --repo %s",
           "dirty": "%d uncommitted file(s) not indexed",
           "none": "n/a — index not built (run %s update)", "hub": "n/a — hub not configured",
           "task_missing": "task %s not found — generic brief"},
    "vi": {"fresh": "tươi", "stale": "lệch %s commit — đang cập nhật nền",
           "stale_noupd": "lệch %s commit", "stale_scan": "lệch %s commit — làm mới: hub-scan --repo %s",
           "dirty": "%d file chưa commit chưa được index",
           "none": "n/a — index not built (run %s update)", "hub": "n/a — hub not configured",
           "task_missing": "không thấy task %s — brief chung"},
}


# ---------------------------------------------------------------- helpers -----------------------------------
def cli_path():
    return os.environ.get("CLAUDEHUT_INDEX_BIN") or os.path.join(os.path.dirname(os.path.dirname(HERE)), "bin",
                                                                 "claudehut-index")


def git(repo, *args, **kw):
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0", LC_ALL="C")
    try:
        r = subprocess.run(["git", "-C", repo] + list(args), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           env=env, timeout=kw.get("timeout", 30))
    except Exception:
        return None
    if r.returncode != 0:
        return None
    return r.stdout.decode("utf-8", "replace")


def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return default


def write_atomic(path, text):
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, path)


def sha1_file(path):
    h = hashlib.sha1()
    try:
        with open(path, "rb") as f:
            h.update(f.read())
    except OSError:
        return None
    return h.hexdigest()


def clip(text, budget):
    b = text.encode("utf-8")
    if len(b) <= budget:
        return text
    return b[:max(0, budget - 4)].decode("utf-8", "ignore").rstrip() + " …"


class Ctx:
    def __init__(self, plane_arg):
        if plane_arg:
            self.plane = os.path.abspath(plane_arg)
            base = os.path.dirname(os.path.dirname(self.plane))
        else:
            base = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()
        top = git(base, "rev-parse", "--show-toplevel")
        self.is_git = top is not None
        self.repo = os.path.realpath(top.strip()) if top else os.path.realpath(base)
        if not plane_arg:
            self.plane = os.path.join(self.repo, ".claude", "claudehut")
        self.idx = os.path.join(self.plane, "index")
        self.topo = read_json(os.path.join(self.plane, "topology.json"), {}) or {}
        self.svc = self.topo.get("service") or os.path.basename(self.repo.rstrip("/")) or "repo"
        self.mode = self.topo.get("mode") or "mono"
        self.lang = resolve_language(self.plane, self.topo)  # one order for bootstrap, status, MEMORY.md (ADR-R7)
        self.m = MSG[self.lang]

    def has_plane(self):
        return os.path.isdir(self.plane)

    def meta(self):
        return read_json(os.path.join(self.idx, "meta.json"))

    def files_state(self):
        """index/files.json {files:{path:sha1}, dirty:[...]} — kept out of meta.json so the hooks' bash read of
        meta.json stays small (UserPromptSubmit fast path, 05 AC12)."""
        f = read_json(os.path.join(self.idx, "files.json"), {}) or {}
        return (f.get("files") or {}), (f.get("dirty") or [])

    def rows(self):
        out = []
        try:
            with open(os.path.join(self.idx, "components.jsonl"), encoding="utf-8") as f:
                for ln in f:
                    ln = ln.strip()
                    if ln:
                        try:
                            out.append(json.loads(ln))
                        except ValueError:
                            pass
        except OSError:
            pass
        return out

    def legacy(self):
        """v0.11 reuse-index.json, read only (never migrated): {path: {purpose, tags}} for entries whose path is
        an existing file (07 §4.2; D7)."""
        data = read_json(os.path.join(self.plane, "reuse-index.json"))
        ents = data.get("components") if isinstance(data, dict) else data
        out = {}
        for e in ents if isinstance(ents, list) else []:
            p = e.get("path") if isinstance(e, dict) else None
            if isinstance(p, str) and p and os.path.isfile(os.path.join(self.repo, p)):
                out[p] = {"purpose": str(e.get("purpose") or "")[:160],
                          "tags": [str(t) for t in (e.get("tags") or []) if isinstance(t, (str, int))][:8]}
        return out

    def rows_enriched(self):
        rows, leg = self.rows(), self.legacy()
        for r in rows:
            e = leg.get(r.get("file"))
            if e and r["kind"] not in ("endpoint", "listener", "producer", "router"):
                if not r.get("purpose") and e["purpose"]:
                    r["purpose"] = e["purpose"]
                if e["tags"]:
                    r["tags"] = e["tags"]
        return rows

    def head(self):
        h = git(self.repo, "rev-parse", "--verify", "-q", "HEAD") if self.is_git else None
        return h.strip() if h else None

    def commit_known(self, sha):
        return bool(sha) and git(self.repo, "cat-file", "-e", sha + "^{commit}") is not None

    def dirty_paths(self):
        """Tracked-modified + untracked (not ignored) paths, repo-relative, excluding the plane."""
        if not self.is_git:
            return []
        out = git(self.repo, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--no-renames")
        if out is None:
            return []
        paths = []
        for ent in out.split("\0"):
            if len(ent) > 3:
                p = ent[3:]
                if not p.startswith(".claude/"):
                    paths.append(p)
        return sorted(set(paths))

    def lock_held(self):
        lk = os.path.join(self.idx, ".lock")
        try:
            return time.time() - os.stat(lk).st_mtime < LOCK_STALE_S
        except OSError:
            return False


def list_files(ctx):
    if ctx.is_git:
        out = git(ctx.repo, "ls-files", "-z", "-co", "--exclude-standard")
        files = [p for p in (out or "").split("\0") if p]
    else:
        files = []
        for d, dirs, fs in os.walk(ctx.repo):
            dirs[:] = [x for x in dirs if x not in (".git", "build", "target", ".gradle", "node_modules", ".claude")]
            for f in fs:
                files.append(os.path.relpath(os.path.join(d, f), ctx.repo))
    return sorted(p for p in files if not p.startswith(".claude/") and os.path.isfile(os.path.join(ctx.repo, p)))


def read_text(ctx, rel):
    with open(os.path.join(ctx.repo, rel), encoding="utf-8", errors="replace") as f:
        return f.read()


# ---------------------------------------------------------------- freshness -----------------------------------
def freshness(ctx, fast=False):
    meta = ctx.meta()
    head = ctx.head()
    st = {"svc": ctx.svc, "mode": ctx.mode, "language": ctx.lang, "plane": ctx.plane, "repo": ctx.repo,
          "cli": cli_path(), "indexed_commit": None, "indexed_at": None, "head": head, "behind": None,
          "dirty": None, "updating": ctx.lock_held(), "stale": True, "built": False, "counts": {},
          "hub": ctx.topo.get("hub") or os.environ.get("CLAUDEHUT_HUB") or None, "ua": None}
    if meta and meta.get("schema") == SCHEMA:
        st.update(built=True, indexed_commit=meta.get("indexed_commit"), indexed_at=meta.get("indexed_at"),
                  counts=meta.get("counts") or {}, tool_version=meta.get("tool_version"))
        ic = meta.get("indexed_commit")
        if ic and head:
            if ic == head:
                st["behind"] = 0
            elif ctx.commit_known(ic):
                n = git(ctx.repo, "rev-list", "--count", "%s..%s" % (ic, head))
                st["behind"] = int(n.strip()) if n else None
        elif not ctx.is_git or (not ic and not head):
            st["behind"] = 0
        if not fast:
            files, was_dirty = ctx.files_state()
            dirty = [p for p in ctx.dirty_paths() if extract.is_source(p)
                     and sha1_file(os.path.join(ctx.repo, p)) != files.get(p)]
            dirty += [p for p in was_dirty if p not in dirty
                      and sha1_file(os.path.join(ctx.repo, p)) != files.get(p)]
            st["dirty"] = len(dirty)
        st["stale"] = st["behind"] != 0 or ic != head
    if not fast:
        st["ua"] = ua_status(ctx)
    return st


def ua_status(ctx):
    for d in (".understand-anything", ".ua"):
        m = read_json(os.path.join(ctx.repo, d, "meta.json"))
        if isinstance(m, dict):
            sha = m.get("gitCommitHash")
            behind = None
            if sha and ctx.commit_known(sha):
                n = git(ctx.repo, "rev-list", "--count", "%s..HEAD" % sha)
                behind = int(n.strip()) if n else None
            return {"dir": d, "behind": behind, "commit": sha}
    return None


def banner(ctx, st, spawned):
    if not st["built"]:
        return ctx.m["none"] % cli_path()
    sha7 = (st["indexed_commit"] or "none")[:7]
    if st["stale"]:
        n = "?" if st["behind"] is None else str(st["behind"])
        state = (ctx.m["stale"] if spawned or st["updating"] else ctx.m["stale_noupd"]) % n
    else:
        state = ctx.m["fresh"]
    extra = ""
    if st.get("dirty"):
        extra = " · " + ctx.m["dirty"] % st["dirty"]
    return "Index %s@%s (%s)%s" % (ctx.svc, sha7, state, extra)


def maybe_spawn(ctx, st):
    """brief/svc on a stale index start a detached update (§7). Never when disabled, locked or unbuilt-plane."""
    if not st["stale"] or st["updating"] or os.environ.get("CLAUDEHUT_INDEX_NO_SPAWN") == "1" or not ctx.has_plane():
        return False
    return spawn_update(ctx, [])


def spawn_update(ctx, extra):
    try:
        subprocess.Popen([sys.executable, "-B", os.path.abspath(__file__), "update", "--plane", ctx.plane] + extra,
                         cwd=ctx.repo, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL, start_new_session=True, close_fds=True)
        return True
    except Exception:
        return False


# ---------------------------------------------------------------- update ------------------------------------
class Lock:
    def __init__(self, ctx):
        self.path = os.path.join(ctx.idx, ".lock")
        self.ok = False

    def __enter__(self):
        for _ in range(2):
            try:
                os.mkdir(self.path)
                self.ok = True
                return self
            except FileExistsError:
                try:
                    age = time.time() - os.stat(self.path).st_mtime
                except OSError:
                    continue
                if age < LOCK_STALE_S:
                    return self
                shutil.rmtree(self.path, ignore_errors=True)
        return self

    def __exit__(self, *a):
        if self.ok:
            shutil.rmtree(self.path, ignore_errors=True)


def cmd_update(ctx, opts):
    if not ctx.has_plane():
        return out_line(opts, {"updated": False, "reason": "no plane"}, "index: no plane at %s — nothing to update" % ctx.plane)
    refresh_shim()
    if ctx.mode == "microservice" and not opts.get("hub_sync"):  # 07 §7: a microservice update always ends in hub-sync
        h = hub.find_hub(ctx.plane, ctx.topo, opts.get("hub"))
        opts["hub_sync"] = bool(h and os.path.isdir(h))
    if opts.get("detach"):
        extra = (["--full"] if opts.get("full") else []) + (["--hub-sync"] if opts.get("hub_sync") else []) + \
            (["--hub", opts["hub"]] if opts.get("hub") else [])
        ok = spawn_update(ctx, extra)
        return out_line(opts, {"started": ok}, "index: update started in background" if ok else "index: could not start update")
    os.makedirs(ctx.idx, exist_ok=True)
    gi = os.path.join(ctx.idx, ".gitignore")
    if not os.path.exists(gi):
        write_atomic(gi, "*\n")
    t0 = time.time()
    with Lock(ctx) as lk:
        if not lk.ok:
            return out_line(opts, {"updated": False, "reason": "locked"}, "index: update skipped — another update holds index/.lock")
        if not opts.get("hub_sync"):
            return do_update(ctx, opts, t0)
        do_update(ctx, opts, t0)
    return hub_sync_here(ctx, opts, [ctx.repo])


def hub_sync_here(ctx, opts, repos):
    h = hub.find_hub(ctx.plane, ctx.topo, opts.get("hub"))
    if not h:
        return out_line(opts, {"synced": False, "reason": "no hub"}, "hub: " + MSG["en"]["hub"])
    r = hub.sync(h, repos)
    return out_line(opts, r, hub.summary_line(r))


def cmd_hub_sync(ctx, opts):
    """hub-sync [--hub DIR] [--repo PATH]…: register planes, rebuild the hub from every registered service."""
    return hub_sync_here(ctx, opts, opts.get("repos") or [])


def cmd_hub_scan(ctx, opts):
    """hub-scan --repo PATH… [--hub DIR]: register repos without a plane; they are scanned read-only."""
    if not opts.get("repos"):
        print("index: usage: hub-scan --repo PATH [--repo PATH…] [--hub DIR]")
        return 0
    return hub_sync_here(ctx, opts, opts["repos"])


def do_update(ctx, opts, t0):
    meta = ctx.meta() or {}
    head = ctx.head()
    ic = meta.get("indexed_commit")
    files_meta, was_dirty = ctx.files_state()
    reason = None
    if opts.get("full"):
        reason = "requested"
    elif meta.get("schema") != SCHEMA or meta.get("tool_version") != TOOL_VERSION:
        reason = "no index" if not meta else "extractor changed"
    elif ctx.is_git and (not ic or not ctx.commit_known(ic)):
        reason = "indexed_commit unknown"
    all_files = list_files(ctx)
    sources = [p for p in all_files if extract.is_source(p)]
    lib = extract.library_info(all_files, lambda rel: read_text(ctx, rel) if os.path.isfile(os.path.join(ctx.repo, rel)) else None)
    lib_key = [m["artifact"] + "@" + m["dir"] for m in lib["modules"]] if lib else None
    if reason is None and meta.get("library") != lib_key:
        reason = "library layout changed"
    changed = []
    if reason is None:
        cand = set(ctx.dirty_paths()) | set(was_dirty)
        if ctx.is_git and ic and head and ic != head:
            d = git(ctx.repo, "diff", "--name-only", "-z", "--no-renames", "%s..%s" % (ic, head))
            cand |= {p for p in (d or "").split("\0") if p}
        if not ctx.is_git:
            cand |= set(sources) | set(files_meta)
        for p in sorted(cand):
            if not extract.is_source(p):
                continue
            if sha1_file(os.path.join(ctx.repo, p)) != files_meta.get(p):
                changed.append(p)
        contract_touch = any(extract.is_contract_input(p) for p in cand)
        if not changed and not contract_touch and ic == head:
            return out_line(opts, {"updated": False, "reason": "up to date", "indexed_commit": ic},
                            "index: up to date (%s)" % ((ic or "none")[:7]))
        if len(changed) > FULL_RATIO * max(1, len(files_meta)) and len(changed) > 3:
            reason = ">30% of files changed"
    if reason is None:
        mode = "incremental"
        drop = set(changed)
        rows = [r for r in ctx.rows() if r.get("file") not in drop and r.get("kind") != "module"]
        files = {p: s for p, s in files_meta.items() if p not in drop}
        todo = [p for p in changed if os.path.isfile(os.path.join(ctx.repo, p))]
    else:
        mode = "full"
        rows, files, todo = [], {}, sources
    rows.extend(extract.library_rows(lib, ctx.svc))  # recomputed every update: build files are not sources
    for p in todo:
        try:
            rows.extend(extract.extract_file(p, read_text(ctx, p), ctx.svc, lib))
        except Exception as e:  # one unparsable file never fails the index
            sys.stderr.write("extract %s: %s\n" % (p, e))
        files[p] = sha1_file(os.path.join(ctx.repo, p))
    rows = extract.sort_rows(rows)
    texts = {}
    for p in all_files:
        if extract.is_contract_input(p):
            try:
                texts[p] = read_text(ctx, p)
            except OSError:
                pass
    contracts = extract.extract_contracts(rows, texts)
    counts = {"total": len(rows)}
    for r in rows:
        counts[r["kind"]] = counts.get(r["kind"], 0) + 1
    dirty_now = sorted(p for p in ctx.dirty_paths() if extract.is_source(p))
    write_atomic(os.path.join(ctx.idx, "components.jsonl"),
                 "".join(json.dumps(r, ensure_ascii=False, sort_keys=True) + "\n" for r in rows))
    write_atomic(os.path.join(ctx.idx, "contracts.json"),
                 json.dumps(dict(contracts, schema=SCHEMA, svc=ctx.svc), ensure_ascii=False, indent=1, sort_keys=True) + "\n")
    write_atomic(os.path.join(ctx.idx, "files.json"),
                 json.dumps({"schema": SCHEMA, "files": dict(sorted(files.items())), "dirty": dirty_now}, indent=1) + "\n")
    if os.environ.get("CLAUDEHUT_INDEX_TEST_FAIL") == "before-meta":
        raise RuntimeError("injected failure before meta.json")
    new_meta = {"schema": SCHEMA, "indexed_commit": head, "indexed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "tool_version": TOOL_VERSION, "extractor": "regex/python3-stdlib", "svc": ctx.svc, "counts": counts,
                "library": lib_key,
                "mode": mode, "reextracted": len(todo), "elapsed_ms": int((time.time() - t0) * 1000)}
    # indexed_commit first: hc_indexed_commit reads only the head of this file.
    order = ("schema", "indexed_commit", "indexed_at", "tool_version")
    new_meta = dict([(k, new_meta[k]) for k in order] + sorted((k, v) for k, v in new_meta.items() if k not in order))
    write_atomic(os.path.join(ctx.idx, "meta.json"), json.dumps(new_meta, indent=1) + "\n")
    summary = {k: new_meta[k] for k in ("indexed_commit", "mode", "reextracted", "counts", "elapsed_ms")}
    summary.update(updated=True, reason=reason)
    return out_line(opts, summary,
                    "index: updated %s %s@%s components=%d reextracted=%d (%d ms)%s" % (
                        mode, ctx.svc, (head or "none")[:7], len(rows), len(todo), new_meta["elapsed_ms"],
                        " — full: %s" % reason if reason else ""))


def out_line(opts, obj, text):
    print(json.dumps(obj, ensure_ascii=False, sort_keys=True) if opts.get("json") else text)
    return 0


# ---------------------------------------------------------------- read commands --------------------------------
def cmd_status(ctx, opts):
    if not ctx.has_plane():
        return out_line(opts, {"plane": None}, "index: no plane at %s" % ctx.plane)
    st = freshness(ctx, fast=opts.get("fast"))
    if opts.get("json"):
        print(json.dumps(st, ensure_ascii=False, sort_keys=True))
        return 0
    lines = [banner(ctx, st, False)]
    if st["built"]:
        c = st["counts"]
        lines.append("components %d: %s" % (c.get("total", 0), ", ".join(
            "%s %d" % (k, c[k]) for k in extract.KIND_ORDER if c.get(k))))
        lines.append("indexed %s · head %s · behind %s · dirty %s%s" % (
            (st["indexed_commit"] or "none")[:7], (st["head"] or "none")[:7],
            "?" if st["behind"] is None else st["behind"], "-" if st["dirty"] is None else st["dirty"],
            " · updating" if st["updating"] else ""))
    ua = st.get("ua")
    if ua:
        lines.append("graph %s: %s commit(s) behind" % (ua["dir"], "?" if ua["behind"] is None else ua["behind"]))
    lines.append("cli: %s status|brief|find|svc|links" % cli_path())
    print(clip("\n".join(lines), 1500))
    return 0


def tokens(text):
    text = re.sub(r"([a-z0-9])([A-Z])", r"\1 \2", text or "")
    return [w for w in re.split(r"[^A-Za-z0-9]+", text.lower()) if len(w) >= 3 and w not in STOP]


def hay(r):
    return {
        "name": set(tokens(r.get("name", ""))),
        "where": set(tokens(" ".join([r.get("fqn", ""), r.get("file", ""), (r.get("http") or {}).get("path", ""),
                                      r.get("topic") or "", r.get("table") or "", r.get("target") or ""]))),
        "purpose": set(tokens(r.get("purpose", "") + " " + " ".join(r.get("tags") or []))),
    }


def rank(rows, terms):
    q = [t for t in dict.fromkeys(terms)]
    scored = []
    for r in rows:
        h = hay(r)
        s = sum(3 * (t in h["name"]) + 2 * (t in h["where"]) + 1 * (t in h["purpose"]) for t in q)
        if q and s == 0:
            continue
        scored.append((-s, KIND_W.get(r["kind"], 99), r.get("file", ""), r.get("line", 0), r))
    scored.sort(key=lambda x: x[:4])
    return [x[-1] for x in scored]


def row_line(r):
    extra = ""
    if r.get("http"):
        extra = " %s %s" % (r["http"]["method"], r["http"]["path"])
    elif r["kind"] in ("listener", "producer"):
        extra = " topic=%s" % (r.get("topic") or r.get("topic_expr") or "?")
    elif r.get("table"):
        extra = " table=%s" % r["table"]
    elif r["kind"] == "client" and r.get("target"):
        extra = " → %s" % r["target"]
    elif r.get("props_prefix"):
        extra = " prefix=%s%s" % (r["props_prefix"], " (%d keys)" % len(r["props"]) if r.get("props") else "")
    elif r["kind"] == "bean" and r.get("type"):
        extra = " : %s" % r["type"]
    if r.get("module") and r["kind"] != "module":
        extra += " [%s]" % r["module"]
    head = "%s %s%s %s:%d" % (r["kind"], r.get("fqn") or r["name"], extra, r["file"], r["line"])
    if r.get("purpose"):
        p = r["purpose"]
        head += " — " + (p if len(p) <= 100 else p[:99].rstrip() + "…")
    return head


def task_terms(ctx, tid):
    if not tid or not re.fullmatch(r"[A-Za-z0-9._-]+", tid):
        return []
    d = os.path.join(ctx.plane, "tasks", tid)
    tj = read_json(os.path.join(d, "task.json"), {}) or {}
    words = [tid, tj.get("slug", ""), tj.get("title", "")]
    for name in ("task.md", "brainstorm.md", "spec.md"):
        try:
            with open(os.path.join(d, name), encoding="utf-8", errors="replace") as f:
                words.append(f.read(2048))
        except OSError:
            pass
    return tokens(" ".join(words))


def cmd_brief(ctx, opts):
    """Text: Markdown <= budget. --json (the shared contract): {budget, bytes, sections:[{name, lines, rows?}], markdown}
    -- sections hold exactly the lines the markdown kept, so the two cannot drift."""
    budget = int(opts.get("budget") or 3000)
    own = os.path.join(ctx.plane, "hub")  # only at the hub / workspace root: a service plane without an index
    if ctx.has_plane() and not ctx.meta() and os.path.isfile(os.path.join(own, "services.json")):  # stays "not built"
        return brief_hub(ctx, opts, os.path.realpath(own), budget)
    if not ctx.has_plane() or not ctx.meta():
        md = clip(ctx.m["none"] % cli_path(), budget - 1)
        return out_line(opts, {"budget": budget, "bytes": len((md + "\n").encode("utf-8")),
                               "sections": [{"name": "banner", "lines": [md]}], "markdown": md}, md)
    st = freshness(ctx)
    spawned = maybe_spawn(ctx, st)
    tid = opts.get("task")
    terms = tokens(" ".join(opts["args"])) + task_terms(ctx, tid)
    rows = ctx.rows_enriched()
    hits = rank(rows, terms)
    fallback = False
    if not hits:
        hits, fallback = rank(rows, []), True
    head = ["%s · %d components" % (banner(ctx, st, spawned), len(rows)),
            "CLI: %s find <term> [--kind K] | svc | status" % cli_path()]
    if tid and not (re.fullmatch(r"[A-Za-z0-9._-]+", tid) and tid not in (".", "..")
                    and os.path.isdir(os.path.join(ctx.plane, "tasks", tid))):
        head.append(ctx.m["task_missing"] % tid)
    if terms and fallback:
        head.append("(no component matched %s — top components by kind)" % " ".join(terms[:6]))
    top = hits[:12]
    files = {r["file"] for r in top}
    rel = [r for r in rows if r["kind"] in ("listener", "producer", "client", "entity") and r["file"] in files]
    rel += [r for r in rows if r["kind"] in ("listener", "producer") and r not in rel]
    rel = rel[:8]
    top = [r for r in top if not (r["kind"] in ("listener", "producer") and r in rel)]  # listed once, under Contracts
    # (name, title, rows or plain lines)
    secs = [("banner", None, head), ("top", "Top components:", top), ("contracts", "Contracts:", rel),
            ("neighbours", None, ["Neighbours: %s" % (ctx.m["hub"] if not st["hub"] else "see %s svc" % cli_path())])]
    flat = []  # (section index, line, row or None)
    for k, (name, title, items) in enumerate(secs):
        if title and not items:
            continue
        if title:
            flat.append((k, title, None))
        flat += [(k, ("- " + row_line(x)) if isinstance(x, dict) else x, x if isinstance(x, dict) else None) for x in items]
    out, kept, used, more = [], [], 0, None
    for i, (k, ln, row) in enumerate(flat):
        n = len((ln + "\n").encode("utf-8"))
        if used + n > budget - 48:
            more = clip("… (+%d more lines — use find)" % (len(flat) - i), budget - used)
            out.append(more)
            break
        out.append(ln)
        kept.append((k, ln, row))
        used += n
    text = clip("\n".join(out), budget - 1)  # print's newline counts
    if opts.get("json"):
        sections = []
        for k, (name, title, _items) in enumerate(secs):
            mine = [(ln, row) for kk, ln, row in kept if kk == k]
            if not mine:
                continue
            sec = {"name": name, "lines": [ln for ln, _ in mine]}
            if any(row for _, row in mine):
                sec["rows"] = [row for _, row in mine if row]
            sections.append(sec)
        if more:
            sections.append({"name": "more", "lines": [more]})
        print(json.dumps({"budget": budget, "bytes": len((text + "\n").encode("utf-8")), "sections": sections,
                          "markdown": text}, ensure_ascii=False, sort_keys=True))
        return 0
    print(text)
    return 0


def brief_hub(ctx, opts, h, budget):
    """brief at the hub / workspace root (no index of its own): rank the components of every registered service
    (links/<svc>.json), absolute paths so an agent can Read them (07 §5, AC-12)."""
    rows = []
    for name in sorted(hub.services_of(h)):
        link = hub.read_link(h, name)
        if not link:
            continue
        base = os.path.normpath(os.path.join(hub.hub_root(h), link.get("path") or name))
        rows += [dict(r, file=os.path.join(base, r["file"]), svc=name) for r in link.get("components") or []]
    terms = tokens(" ".join(opts["args"]))
    hits = rank(rows, terms)
    head = ["Hub %s · %d services · %d components" % (h, len(hub.services_of(h)), len(rows)),
            "CLI: %s svc <service> | links [--service S] | find <term> --svc S" % cli_path()]
    if terms and not hits:
        hits = rank(rows, [])
        head.append("(no component matched %s — top components by kind)" % " ".join(terms[:6]))
    out, kept, used, more = [], [], 0, None
    for ln in head + ["Top components:"]:
        out.append(ln)
        used += len((ln + "\n").encode("utf-8"))
    for i, r in enumerate(hits[:12]):
        ln = "- [%s] %s" % (r["svc"], row_line(r))
        n = len((ln + "\n").encode("utf-8"))
        if used + n > budget - 48:
            more = "… (+%d more — use find --svc)" % (len(hits[:12]) - i)
            out.append(more)
            break
        out.append(ln)
        kept.append(r)
        used += n
    text = clip("\n".join(out), budget - 1)
    if opts.get("json"):
        secs = [{"name": "banner", "lines": head}]
        if kept:
            secs.append({"name": "top", "lines": out[len(head):len(head) + 1 + len(kept)], "rows": kept})
        if more:
            secs.append({"name": "more", "lines": [more]})
        print(json.dumps({"budget": budget, "bytes": len((text + "\n").encode("utf-8")), "sections": secs,
                          "markdown": text}, ensure_ascii=False, sort_keys=True))
        return 0
    print(text)
    return 0


def cmd_find(ctx, opts):
    if not opts["args"] and not opts.get("kind"):
        print("index: usage: find <term|glob> [--kind K] [--svc S]")
        return 0
    if not ctx.meta() and not (opts.get("svc") and opts["svc"] != ctx.svc):
        print(ctx.m["none"] % cli_path())
        return 0
    term = " ".join(opts["args"]).lower() or "*"
    kind = opts.get("kind")
    glob = any(c in term for c in "*?[")
    res = []
    rows = None
    if opts.get("svc") and opts["svc"] != ctx.svc:
        h = hub.find_hub(ctx.plane, ctx.topo, opts.get("hub"))
        link = hub.read_link(h, hub.resolve_svc(h, opts["svc"])) if h else None
        if not link:
            print(MSG["en"]["hub"] if not h else "index: service %s is not in the hub (%s)" % (opts["svc"], h))
            return 0
        base = os.path.normpath(os.path.join(hub.hub_root(h), link["path"]))  # absolute: an agent Reads these rows
        rows = [dict(r, file=os.path.join(base, r["file"])) for r in link["components"]]
    for r in (rows if rows is not None else ctx.rows_enriched()):
        if kind and r["kind"] != kind:
            continue
        fields = [r.get("name", ""), r.get("fqn", ""), r.get("file", ""), (r.get("http") or {}).get("path", ""),
                  r.get("topic") or "", r.get("table") or "", r.get("target") or "", r.get("topic_prop") or "",
                  r.get("props_prefix") or "", r.get("module") or "", r.get("type") or ""]
        fields += list(r.get("tags") or []) + list(r.get("props") or [])
        fields = [f.lower() for f in fields if f]
        if (glob and any(fnmatch.fnmatchcase(f, term) for f in fields)) or (not glob and any(term in f for f in fields)):
            res.append(r)
    res.sort(key=lambda r: (KIND_W.get(r["kind"], 99), r.get("fqn") or r["name"], r["line"]))
    limit = int(opts.get("limit") or 50)
    if opts.get("json"):
        print(json.dumps(res[:limit], ensure_ascii=False, sort_keys=True))
        return 0
    if not res:
        print("index: no component matches '%s'%s" % (term, " (kind %s)" % kind if kind else ""))
        return 0
    lines = [row_line(r) for r in res[:limit]]
    if len(res) > limit:
        lines.append("… (+%d more)" % (len(res) - limit))
    print(clip("\n".join(lines), 6000))
    return 0


def cmd_svc(ctx, opts):
    name = opts["args"][0] if opts["args"] else ctx.svc
    if name != ctx.svc:
        return svc_other(ctx, opts, name)
    if not ctx.meta():
        print(ctx.m["none"] % cli_path())
        return 0
    st = freshness(ctx)
    spawned = maybe_spawn(ctx, st)
    rows = ctx.rows()
    contracts = read_json(os.path.join(ctx.idx, "contracts.json"), {}) or {}
    by = {}
    for r in rows:
        by.setdefault(r["kind"], []).append(r)
    if opts.get("json"):
        print(json.dumps({"svc": ctx.svc, "status": st, "endpoints": [dict(r["http"], at="%s:%d" % (r["file"], r["line"])) for r in by.get("endpoint", [])],
                          "consumes": sorted({r.get("topic") or "?" for r in by.get("listener", [])}),
                          "produces": sorted({r.get("topic") or r.get("topic_expr") or "?" for r in by.get("producer", [])}),
                          "clients": [{"name": r["name"], "target": r.get("target")} for r in by.get("client", [])],
                          "tables": sorted({r["table"] for r in by.get("entity", []) + by.get("migration", []) if r.get("table")}),
                          "db": contracts.get("db", []), "libs": contracts.get("libs", [])}, ensure_ascii=False, sort_keys=True))
        return 0
    c = st["counts"]
    L = ["# %s (%s) — %s" % (ctx.svc, ctx.mode, banner(ctx, st, spawned)),
         "components %d: %s" % (c.get("total", 0), ", ".join("%s %d" % (k, c[k]) for k in extract.KIND_ORDER if c.get(k)))]
    eps = by.get("endpoint", [])
    if eps:
        L.append("Endpoints (%d):" % len(eps))
        L += ["- %s %s → %s %s:%d" % (r["http"]["method"], r["http"]["path"], r["name"], r["file"], r["line"]) for r in eps[:14]]
        if len(eps) > 14:
            L.append("- … +%d (find --kind endpoint)" % (len(eps) - 14))
    subs = sorted({r.get("topic") or "?" for r in by.get("listener", [])})
    pubs = sorted({r.get("topic") or r.get("topic_expr") or "?" for r in by.get("producer", [])})
    if subs or pubs:
        L.append("Kafka: consumes %s; produces %s" % (", ".join(subs) or "-", ", ".join(pubs) or "-"))
    cl = by.get("client", [])
    if cl:
        L.append("Clients: " + ", ".join("%s%s" % (r["name"], " → " + r["target"] if r.get("target") else "") for r in cl[:10]))
    envs = sorted({h["env"] for h in contracts.get("http_clients", []) if h.get("env")})
    if envs:
        L.append("Client env: " + ", ".join(envs[:12]))
    tabs = sorted({r["table"] for r in by.get("entity", []) + by.get("migration", []) if r.get("table")})
    if tabs:
        L.append("Tables: " + ", ".join(tabs[:16]))
    dbs = sorted({d["name"] for d in contracts.get("db", [])})
    if dbs:
        L.append("DB: " + ", ".join(dbs))
    libs = contracts.get("libs", [])
    if libs:  # a library group with ≥2 artifacts here (io.f8a.summer) first, then the rest by group
        groups = {}
        for x in libs:
            groups.setdefault(x["coord"].split(":")[0], set()).add(x["coord"].split(":", 1)[-1])
        order = sorted(groups, key=lambda g: (-len(groups[g]), g))
        L.append("Libs: " + "; ".join("%s: %s" % (g, ", ".join(sorted(groups[g])[:12])) for g in order[:2])
                 + ("; +%d group(s)" % (len(order) - 2) if len(order) > 2 else ""))
    svcs = by.get("service", [])
    if svcs:
        L.append("Services: " + ", ".join(r["name"] for r in svcs[:16]))
    print(clip("\n".join(L), 2499))  # ≤2.5 KB including print's newline
    return 0


def svc_other(ctx, opts, name):
    """svc <other>: the hub's view of another service, ≤2.5 KB. A stale view gets a banner and a detached update of
    that service's plane (+ hub-sync), never a wait (07 §5)."""
    h = hub.find_hub(ctx.plane, ctx.topo, opts.get("hub"))
    name = hub.resolve_svc(h, name) if h else name  # the repo dir name (auth-ms) works for the key (auth-service)
    link = hub.read_link(h, name) if h else None
    if not h:
        return out_line(opts, {"svc": name, "note": "hub not configured"}, "%s (service %s is not this repo)" % (ctx.m["hub"], name))
    if not link:
        known = sorted(hub.services_of(h))
        return out_line(opts, {"svc": name, "hub": h, "note": "not in hub", "services": known},
                        "index: service %s is not in the hub — known: %s" % (name, ", ".join(known) or "none"))
    n, repo, ent = hub.behind(h, name)
    note = ""
    if n:
        spawned = False
        plane = os.path.join(repo, ".claude", "claudehut")
        if ent.get("has_plane") and os.environ.get("CLAUDEHUT_INDEX_NO_SPAWN") != "1" and os.path.isdir(plane):
            try:
                subprocess.Popen([sys.executable, "-B", os.path.abspath(__file__), "update", "--hub-sync", "--hub", h,
                                  "--plane", plane],
                                 cwd=repo, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                 start_new_session=True, close_fds=True)
                spawned = True
            except Exception:
                pass
        if spawned:
            note = " [%s]" % (ctx.m["stale"] % n)
        elif not ent.get("has_plane"):  # a hub-scan repo is refreshed by re-scanning it, never by an update
            note = " [%s]" % (ctx.m["stale_scan"] % (n, repo))
        else:
            note = " [%s]" % (ctx.m["stale_noupd"] % n)
    edges = hub.read_links(h).get("edges", [])
    if opts.get("json"):
        print(json.dumps({"svc": name, "hub": h, "behind": n, "link": {k: v for k, v in link.items() if k != "components"},
                          "edges": [e for e in edges if name in (e["from"], e["to"])]}, ensure_ascii=False, sort_keys=True))
        return 0
    print(hub.render_svc(link, edges, note, repo))
    return 0


def cmd_links(ctx, opts):
    """links [--service S] [--type http|kafka|lib|db] [--module M] [--json]: cross-service edges from service-links.json
    (--module: the lib edges of one library module — its artifact or the name without the library prefix)."""
    h = hub.find_hub(ctx.plane, ctx.topo, opts.get("hub"))
    data = hub.read_links(h) if h else None
    if not data:
        return out_line(opts, {"edges": [], "hub": h, "note": "hub not configured" if not h else "hub not synced"},
                        MSG["en"]["hub"] if not h else "hub: no service-links.json yet (run %s hub-sync)" % cli_path())
    s, t, mod = hub.resolve_svc(h, opts.get("service") or opts.get("svc")), opts.get("type"), opts.get("module")
    if mod:  # --module <artifact|short name>: the services a change to that library module impacts
        t = "lib"
    edges = [e for e in data.get("edges", []) if (not s or s in (e["from"], e["to"])) and (not t or e["type"] == t)
             and (not mod or mod in (e.get("module"), e["via"]) or (e.get("module") or "").endswith("-" + mod))]
    unres = [] if mod else [u for u in data.get("unresolved", []) if not s or u.get("svc") == s]
    if opts.get("json"):
        print(json.dumps({"hub": h, "edges": edges, "unresolved": unres}, ensure_ascii=False, sort_keys=True))
        return 0
    def ver(e):
        return "%s%s" % (hub.eff_version(e), " [test]" if e.get("scope") == "test" else "")
    libs = [e for e in edges if e["type"] == "lib"]
    group = t != "lib" or len(libs) > 30  # one line per consumer → library pair unless a narrow lib query
    lines, done = [], set()
    for e in edges:
        if e["type"] != "lib" or not group:
            lines.append("%s → %s %s via %s%s (%s) %s" % (e["from"], e["to"], e["type"], e["via"],
                                                         " @" + ver(e) if e["type"] == "lib" else "", e["confidence"],
                                                         e["evidence"][0]))
            continue
        if (e["from"], e["to"]) in done:
            continue
        done.add((e["from"], e["to"]))
        es = [x for x in libs if (x["from"], x["to"]) == (e["from"], e["to"])]
        lines.append("%s → %s lib %d module(s): %s" % (e["from"], e["to"], len(es), ", ".join(
            "%s %s" % (x.get("module") or x["via"], ver(x)) for x in es) if t == "lib" else
            "(links --type lib%s)" % ("" if s else " --service %s" % e["from"])))
    lines.append("%d edge(s), %d unresolved%s" % (len(edges), len(unres), "" if not unres else " (links --json)"))
    print(clip("\n".join(lines), 6000))
    return 0


def cmd_memory(ctx, opts):
    mem = os.path.join(HERE, "memory.py")
    if not os.path.isfile(mem):
        return out_line(opts, {"memory": False, "reason": "memory.py absent"}, "index: memory generator unavailable")
    if not ctx.has_plane():
        return out_line(opts, {"memory": False, "reason": "no plane"}, "index: no plane at %s" % ctx.plane)
    args = [sys.executable, "-B", mem, "--plane", ctx.plane, "--plugin-root", os.path.dirname(os.path.dirname(HERE))]
    args += ["--" + k.replace("_", "-") for k in ("json", "no_migrate", "check") if opts.get(k)]
    try:
        r = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=60)
        sys.stdout.write(r.stdout.decode("utf-8", "replace") or "index: memory regenerated\n")
    except Exception as e:
        print("index: memory failed — %s" % e)
    return 0


# ---------------------------------------------------------------- git hooks -----------------------------------
def hook_block(hook, cmd):
    guard = '[ "$3" = 1 ] && ' if hook == "post-checkout" else ""
    q = "'" + cmd.replace("'", "'\\''") + "'"
    return "\n".join([
        MARK_START,
        "# claudehut-index install-git-hooks: refresh the ClaudeHut index in the background (never blocks, never exits).",
        "# Remove with: claudehut-index uninstall-git-hooks. Skipped in linked worktrees.",
        'if %s[ "$(git rev-parse --git-dir 2>/dev/null)" = "$(git rev-parse --git-common-dir 2>/dev/null)" ] \\' % guard,
        '  && [ -x %s ] && [ -d "$(git rev-parse --show-toplevel 2>/dev/null)/.claude/claudehut" ]; then' % q,
        '  %s update --detach --plane "$(git rev-parse --show-toplevel)/.claude/claudehut" </dev/null >/dev/null 2>&1 || :' % q,
        "fi",
        MARK_END,
    ]) + "\n"


def own_hooks_path(repo, hp):
    """True when core.hooksPath names the repo's own <git-common-dir>/hooks — the default location spelled out
    (ewallet: party-ms, payment-gateway-ms, report-service-ms), which no hook manager owns."""
    top = (git(repo, "rev-parse", "--show-toplevel") or "").strip() or repo
    common = (git(repo, "rev-parse", "--git-common-dir") or "").strip()
    if not common:
        return False
    hp = os.path.expanduser(hp)
    hp = hp if os.path.isabs(hp) else os.path.join(top, hp)
    common = common if os.path.isabs(common) else os.path.join(repo, common)
    return os.path.realpath(hp) == os.path.realpath(os.path.join(common, "hooks"))


def hook_manager(ctx):
    hp = git(ctx.repo, "config", "--get", "core.hooksPath")
    if hp and hp.strip() and not own_hooks_path(ctx.repo, hp.strip()):
        return "core.hooksPath=%s" % hp.strip()
    for f in (".husky", "lefthook.yml", ".lefthook.yml", "lefthook.yaml", ".lefthook.yaml"):
        if os.path.exists(os.path.join(ctx.repo, f)):
            return "husky" if f == ".husky" else "lefthook (%s)" % f
    return None


def hooks_dir(ctx):
    p = git(ctx.repo, "rev-parse", "--git-path", "hooks")
    if not p:
        return None
    p = p.strip()
    return p if os.path.isabs(p) else os.path.join(ctx.repo, p)


def shim_text(target):
    return ("#!/bin/sh\n# claudehut-index shim (install-git-hooks) — points at the current plugin install\n"
            "t='%s'\n[ -x \"$t\" ] || exit 0\nexec \"$t\" \"$@\"\n" % target.replace("'", "'\\''"))


def refresh_shim():
    """A plugin upgrade moves the versioned install; `update` (run by maintain.sh every SessionStart) re-points an
    existing shim so installed git hooks keep working. Never creates one."""
    data = os.environ.get("CLAUDE_PLUGIN_DATA")
    shim = os.path.join(data or "", "bin", "claudehut-index")
    if not data or not os.path.isfile(shim):
        return
    want = shim_text(os.path.abspath(cli_path()))
    try:
        with open(shim, encoding="utf-8") as f:
            cur = f.read()
        if cur != want:
            write_atomic(shim, want)
            os.chmod(shim, 0o755)
    except OSError:
        pass


def shim_cmd():
    data = os.environ.get("CLAUDE_PLUGIN_DATA")
    target = os.path.abspath(cli_path())
    if not data:
        return target
    d = os.path.join(data, "bin")
    os.makedirs(d, exist_ok=True)
    shim = os.path.join(d, "claudehut-index")
    write_atomic(shim, shim_text(target))
    os.chmod(shim, 0o755)
    return shim


def strip_block(text):
    return re.sub(r"(?ms)^%s\n.*?^%s\n?" % (re.escape(MARK_START), re.escape(MARK_END)), "", text)


def set_topology_flag(ctx, val):
    p = os.path.join(ctx.plane, "topology.json")
    t = read_json(p)
    if isinstance(t, dict) and t.get("git_hooks") != val:
        t["git_hooks"] = val
        write_atomic(p, json.dumps(t, ensure_ascii=False, indent=2) + "\n")


def cmd_install_hooks(ctx, opts):
    if not ctx.is_git:
        return out_line(opts, {"installed": False, "reason": "not a git repo"}, "index: not a git repo — no hooks installed")
    mgr = hook_manager(ctx)
    cmd = shim_cmd()   # the manual block too: a versioned plugin path dies on the next upgrade
    if mgr:
        blocks = "\n".join("## %s\n%s" % (h, hook_block(h, cmd)) for h in HOOKS)
        return out_line(opts, {"installed": False, "reason": mgr, "blocks": {h: hook_block(h, cmd) for h in HOOKS}},
                        "index: %s manages git hooks — nothing written. Add this block to each hook:\n%s" % (mgr, blocks))
    hd = hooks_dir(ctx)
    os.makedirs(hd, exist_ok=True)
    done, manual = [], []
    for h in HOOKS:
        p = os.path.join(hd, h)
        blk = hook_block(h, cmd)
        if os.path.exists(p):
            with open(p, encoding="utf-8", errors="replace") as f:
                cur = f.read()
            first = cur.split("\n", 1)[0]
            if first.startswith("#!") and not re.search(r"\b(sh|bash|zsh|dash|ksh)\b", first):
                manual.append(h)
                continue
            body = strip_block(cur)
            if body.startswith("#!"):
                sheb, _, rest = body.partition("\n")
                new = sheb + "\n" + blk + rest
            else:
                new = "#!/bin/sh\n" + blk + body
        else:
            new = "#!/bin/sh\n" + blk
        write_atomic(p, new)
        os.chmod(p, 0o755)
        done.append(h)
    if done:
        set_topology_flag(ctx, True)
    msg = "index: git hooks installed — %s (%s)" % (", ".join(done) or "none", hd)
    if manual:
        msg += "\nindex: %s not a shell script — add this block by hand:\n%s" % (", ".join(manual), hook_block(manual[0], cmd))
    return out_line(opts, {"installed": bool(done), "hooks": done, "manual": manual, "dir": hd}, msg)


def cmd_uninstall_hooks(ctx, opts):
    if not ctx.is_git:
        return out_line(opts, {"removed": []}, "index: not a git repo")
    mgr = hook_manager(ctx)
    if mgr:
        return out_line(opts, {"removed": [], "reason": mgr},
                        "index: %s manages git hooks — remove the lines between '%s' and '%s' by hand" % (mgr, MARK_START, MARK_END))
    hd = hooks_dir(ctx)
    removed = []
    for h in HOOKS:
        p = os.path.join(hd or "", h)
        if not os.path.isfile(p):
            continue
        with open(p, encoding="utf-8", errors="replace") as f:
            cur = f.read()
        new = strip_block(cur)
        if new == cur:
            continue
        if not new.strip() or re.fullmatch(r"#![^\n]*\n?\s*", new):
            os.remove(p)
        else:
            write_atomic(p, new)
            os.chmod(p, 0o755)
        removed.append(h)
    set_topology_flag(ctx, False)
    return out_line(opts, {"removed": removed}, "index: git hooks removed — %s" % (", ".join(removed) or "none"))


# ---------------------------------------------------------------- main ---------------------------------------
COMMANDS = {"status": cmd_status, "brief": cmd_brief, "find": cmd_find, "svc": cmd_svc, "links": cmd_links,
            "update": cmd_update, "memory": cmd_memory, "install-git-hooks": cmd_install_hooks,
            "uninstall-git-hooks": cmd_uninstall_hooks, "hub-sync": cmd_hub_sync, "hub-scan": cmd_hub_scan}
VALUED = {"--plane", "--budget", "--task", "--kind", "--limit", "--svc", "--service", "--type", "--repo", "--hub",
          "--module"}


def parse(argv):
    opts = {"args": []}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in VALUED and i + 1 < len(argv):
            opts[a[2:]] = argv[i + 1]
            i += 2
            continue
        if a.startswith("--") and "=" in a and a.split("=", 1)[0] in VALUED:
            k, v = a.split("=", 1)
            opts[k[2:]] = v
        elif a in ("--json", "--fast", "--detach", "--full", "--incremental", "--hub-sync", "--no-migrate", "--check"):
            opts[a[2:].replace("-", "_")] = True
        else:
            opts["args"].append(a)
        i += 1
    return opts


def main(argv):
    if not argv or argv[0] in ("-h", "--help", "help"):
        print("usage: claudehut-index <%s> [--json] [--plane DIR]" % "|".join(COMMANDS))
        return 0
    cmd = argv[0]
    fn = COMMANDS.get(cmd)
    if not fn:
        print("index: unknown command '%s' (try: %s)" % (cmd, " ".join(COMMANDS)))
        return 0
    opts = parse(argv[1:])
    if cmd in ("hub-sync", "hub-scan"):  # every --repo counts (repeatable, comma-separated); never a --plane
        rest, repos = argv[1:], []
        for i, a in enumerate(rest):
            v = rest[i + 1] if a == "--repo" and i + 1 < len(rest) else a[7:] if a.startswith("--repo=") else None
            if v:
                repos += [x for x in v.split(",") if x]
        opts["repos"] = repos
        opts.pop("repo", None)
    if opts.get("repo") and not opts.get("plane"):
        opts["plane"] = os.path.join(opts["repo"], ".claude", "claudehut")
    ctx = Ctx(opts.get("plane"))
    return fn(ctx, opts)


if __name__ == "__main__":
    try:
        rc = main(sys.argv[1:])
    except Exception as e:  # exit 0 with one line (§5)
        print("index: error — %s: %s" % (type(e).__name__, str(e)[:200]))
        rc = 0
    sys.exit(rc)
