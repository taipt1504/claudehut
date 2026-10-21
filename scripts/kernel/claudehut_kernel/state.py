"""claudehut-state in the Python kernel (K1/K2, docs/v0.20 04 §1-§2, §7 strangler step 1).

The CLI contract (usage, verbs, messages, exit codes) is the 0.12 one, documented in bin/claudehut-state; the 0.12
bash writer is kept as scripts/legacy/claudehut-state.sh and every suite runs against both. This module is the SOLE
writer of task state:

  state/<sid>.json        {"schema":2,"active_task":"<id>"|null}      — a pointer, nothing else
  tasks/<id>/task.json    the task record (schema 2) — read directly by hooks, so it is written on every transition

Writes are atomic (temp + rename) and serialized by one plane lock, taken the way the bash writer takes it so mixed
installs interoperate: fcntl.flock on state/.state.lock.flock AND the mkdir lock state/.state.lock (30 s stale,
10 s wall clock, then fail-open). Invariants run in-process (gates.run) at the transitions that have them; a gate
crash is recorded as gate.skipped and never refuses a transition.

Port notes (kept identical to the bash writer, on purpose):
  - one timestamp per invocation; JSON written compact, key order preserved, non-ASCII raw (jq -c);
  - jq's `//` falls through on null/false only — never Python's `or` on "", 0 or [];
  - grep -E patterns are translated (POSIX classes → explicit) and applied line by line;
  - plan_review_plan_hash is the sha1 hex of the file bytes (shasum's default), so stored hashes keep matching.
"""
import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
import time

from . import events, gates, plane

VERBS = ("start set-route set-phase set-reuse-scan set-brainstorm set-spec set-plan set-plan-review set-review "
         "set-enforcement set-outstanding set-findings end resume status cost-report "
         "set-bypass set-complexity set-profile mark-skill pause rename route").split()
PHASES = ("discover", "brainstorm", "spec", "plan", "implement", "review", "learn")
PROFILES = ("feature", "bugfix", "audit", "migration", "investigation")
SESSION_RE = re.compile(r"^[A-Za-z0-9_-]+$")
ID_RE = re.compile(r"^[A-Za-z0-9._-]+$")
SP = r"[ \t\n\r\f\v]"   # [[:space:]]
LOCK_STALE = 30
LOCK_WAIT = 10


class Exit(Exception):
    def __init__(self, code):
        Exception.__init__(self, code)
        self.code = code


def dumps(obj):
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"))


def alt(v, default):
    """jq `v // default`: falls through on null and false only."""
    return default if v is None or v is False else v


def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def file_lines(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read().splitlines()
    except OSError:
        return []


class State:
    def __init__(self, argv, legacy):
        self.legacy = legacy
        self.session = ""
        self.args = []
        self._parse(argv)
        self._lock_flock = None
        self._lock_mkdir = None

    # ── output ───────────────────────────────────────────────────────────────────────────────────────────────
    @staticmethod
    def note(msg):
        print(f"claudehut-state: {msg}", file=sys.stderr)

    def err(self, msg):
        self.note(msg)
        raise Exit(1)

    # ── argv ─────────────────────────────────────────────────────────────────────────────────────────────────
    def _parse(self, argv):
        i = 0
        n = len(argv)
        while i < n:
            a = argv[i]
            if a == "--session":
                # B7: skills write `--session ${CLAUDE_SESSION_ID}` unquoted and that variable is empty in Bash, so the
                # next token may be the verb. A value that is empty, a verb or another flag is "no value given"; a
                # QUOTED empty value arrives as '' and is consumed with the flag.
                if i + 1 < n and argv[i + 1] == "":
                    i += 2
                    continue
                v = argv[i + 1] if i + 1 < n else ""
                if v == "" or v in VERBS or v.startswith("--"):
                    i += 1
                else:
                    self.session = v
                    i += 2
                continue
            self.args.append(a)
            i += 1

    def flag(self, name):
        """First `name` in the verb's args → the next arg, or "" (the bash flag() helper)."""
        sa = self.shift_args
        for i, a in enumerate(sa):
            if a == name:
                return sa[i + 1] if i + 1 < len(sa) else ""
        return ""

    def arg0(self):
        return self.shift_args[0] if self.shift_args else ""

    # ── paths ────────────────────────────────────────────────────────────────────────────────────────────────
    def abspath(self, p):
        return p if p.startswith("/") else f"{self.project}/{p}"

    def canon_path(self, p):
        """Lexical normalization against the project (no symlink resolution), as canon_path_state did."""
        if not p.startswith("/"):
            p = f"{self.project}/{p}"
        out = []
        for seg in p.split("/"):
            if seg in ("", "."):
                continue
            if seg == "..":
                if out:
                    out.pop()
                continue
            out.append(seg)
        return "/" + "/".join(out)

    def canon(self, p):
        if not self.canon_path(p).startswith(self.canon_path(self.plane) + "/"):
            self.err(f"artifact path must be under the plane {self.plane_rel}/ (got: {p}) — write it into "
                     f"{self.plane_rel}/tasks/<id>/, not a bare specs/ or .claude/prompt/ path")

    def tmpl(self, p, pattern, msg):
        ap = self.abspath(p)
        if not os.path.isfile(ap):
            return
        rx = re.compile(pattern)
        if not any(rx.search(line) for line in file_lines(ap)):
            self.err(msg)

    # ── state files ──────────────────────────────────────────────────────────────────────────────────────────
    def write_atomic(self, path, obj):
        d = os.path.dirname(path)
        tmp = os.path.join(d, f".state.{os.getpid()}.{int(time.time() * 1e6) % 1000000}")
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(dumps(obj) + "\n")
        os.replace(tmp, path)

    def set_pointer(self, task_id):
        self.write_atomic(self.file, {"schema": 2, "active_task": task_id or None})

    def load(self):
        self.active = ""
        self.task = None
        self.tfile = ""
        self.legacy_state = False
        self.foreign = ""
        self.foreign_owner = ""
        if os.path.isfile(self.file):
            ptr = read_json(self.file)
            if isinstance(ptr, dict) and ptr.get("schema") == 2:
                a = alt(ptr.get("active_task"), "")
                self.active = a if isinstance(a, str) else ("" if a is True else json.dumps(a))
            else:
                self.legacy_state = True
        if self.active.startswith(".") or not ID_RE.match(self.active or "x"):
            self.active = ""
        if self.active:
            self.tfile = os.path.join(self.tasks_dir, self.active, "task.json")
            t = read_json(self.tfile)
            if isinstance(t, dict) and t.get("schema") == 2 and alt(t.get("status"), "active") == "active":
                self.task = t
                owner = alt(t.get("session"), "")
                owner = owner if isinstance(owner, str) else str(owner)
                if owner and owner != self.session:
                    self.foreign, self.foreign_owner = self.active, owner
                    self.active, self.task, self.tfile = "", None, ""
            else:
                self.active, self.tfile = "", ""

    # ── lock ─────────────────────────────────────────────────────────────────────────────────────────────────
    def acquire_lock(self):
        lock = os.path.join(self.state_dir, ".state.lock")
        try:
            fd = os.open(lock + ".flock", os.O_RDWR | os.O_CREAT, 0o644)
            deadline = time.time() + LOCK_WAIT
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    self._lock_flock = fd
                    break
                except OSError:
                    if time.time() >= deadline:
                        os.close(fd)
                        break
                    time.sleep(0.02)
        except OSError:
            pass
        start = time.time()
        hard = badpath = 0
        while True:
            try:
                os.mkdir(lock)
                self._lock_mkdir = lock
                return
            except FileExistsError:
                pass
            except OSError:
                pass
            if os.path.lexists(lock) and not os.path.isdir(lock):
                # a plain file is never a valid lock: clear it once, then retry; if it comes back, proceed
                if not badpath:
                    badpath = 1
                    try:
                        os.unlink(lock)
                    except OSError:
                        pass
                    continue
                return
            if not os.path.isdir(lock):
                hard += 1          # the benign race (holder released) or an unwritable fs: a retry tells them apart
                if hard >= 3:
                    return
                continue
            hard = 0
            try:
                lm = int(os.stat(lock).st_mtime)
            except OSError:
                lm = 0
            now = time.time()
            if lm > 0 and now - lm >= LOCK_STALE:
                try:
                    os.rmdir(lock)
                except OSError:
                    pass
                continue
            if now - start >= LOCK_WAIT:
                return
            time.sleep(0.02)

    def release_lock(self):
        if self._lock_mkdir:
            try:
                os.rmdir(self._lock_mkdir)
            except OSError:
                pass
            self._lock_mkdir = None
        if self._lock_flock is not None:
            try:
                fcntl.flock(self._lock_flock, fcntl.LOCK_UN)
            finally:
                os.close(self._lock_flock)
            self._lock_flock = None

    # ── gates and doclint ────────────────────────────────────────────────────────────────────────────────────
    def task_dir(self):
        return os.path.join(self.tasks_dir, self.active)

    def gate_call(self, which, **kw):
        """In-process gate. Refuse ONLY on an explicit block decision; a crash is recorded and the transition proceeds."""
        ovr = self.flag("--override")
        try:
            rc, out = gates.run(which, os.path.abspath(self.project), os.path.abspath(self.task_dir()),
                                override=ovr or None, ts=self.ts, **kw)
        except Exception as exc:  # noqa: BLE001 — a kernel failure must neither block nor pass silently
            print(f"claudehut-kernel: internal error: {type(exc).__name__}: {exc}", file=sys.stderr)
            rc, out = 3, None
        if rc == 1 and (out or {}).get("decision") == "block":
            self.note(f"{which} refused by the invariant(s) above (gate mode block). Fix them, or re-run with "
                      f"--override \"<reason>\" (recorded).")
            raise Exit(1)
        if rc == 0:
            return out
        self.note(f"gate {which} skipped: kernel unavailable or failed (exit {rc}) — transition proceeds, check "
                  f"`claudehut-kernel selftest`")
        try:
            events.append(self.task_dir(), "gate.skipped", {"gate": which, "rc": rc})
        except OSError:
            pass
        return {}

    def doclint_gate(self, kind, path):
        p = self.abspath(path)
        if not os.path.isfile(p):
            self.err(f"{kind} rejected: {path} does not exist — write it from the {kind} template first, then re-run {self.sub}.")
        route = alt(self.task.get("route"), "")
        profile = alt(self.task.get("profile"), "")
        a = ["--kind", kind]
        if route:
            a += ["--route", str(route)]
        if profile:
            a += ["--profile", str(profile)]
        if kind == "plan":
            sp = alt(self.task.get("spec_path"), "")
            if sp:
                a += ["--spec", self.abspath(sp)]
        engine = os.environ.get("CLAUDEHUT_DOCLINT") or os.path.join(self.root, "scripts", "doclint.sh")
        if os.path.isfile(engine):
            r = subprocess.run(["bash", engine] + a + [p], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            out = r.stdout.decode("utf-8", "replace").rstrip("\n")
            rc = r.returncode
        else:
            out, rc = "", 127
        if out:
            print(out, file=sys.stderr)
        # PLN-3: a total over budget is an event (metric), never a refusal — budgets stay advisory.
        m = None
        for line in out.split("\n"):
            m = re.match(r"^budget: total ([0-9]+)/([0-9]+)", line)
            if m:
                break
        if m and self.active:
            bw, bb = int(m.group(1)), int(m.group(2))
            if bb > 0 and bw > bb:
                events.append(self.task_dir(), "budget.exceeded", {"kind": kind, "words": bw, "budget": bb})
                self.note(f"{kind} is {bw} words against a budget of {bb} (+{(bw - bb) * 100 // bb}%): recorded as "
                          f"budget.exceeded. Cut it to the template's sections before review.")
        if rc == 0:
            return
        if rc == 1:
            self.err(f"{kind} rejected: {path} has structural violation(s) — the 'blocking' lines above. Fix them in "
                     f"place and re-run {self.sub} (budget lines are advisory and never block).")
        extra = f", no engine at {engine}" if rc == 127 else ""
        self.err(f"{kind}: doclint could not check {path} (exit {rc}{extra}) — the structural gate must run before "
                 f"{self.sub} records it.")

    @staticmethod
    def hdr_num(path, key):
        """The number after "<key>:" on the first "> " header line (key not part of a longer key)."""
        for line in file_lines(path):
            if line.startswith(">"):
                m = re.search(r"(^|[^A-Za-z0-9-])" + re.escape(key) + ":" + SP + r"*([0-9]+)", line)
                return m.group(2) if m else ""
        return ""

    def spec_rev_note(self, spec):
        sf = self.abspath(spec)
        pl = alt(self.task.get("plan_path"), "")
        if pl:
            pf = self.abspath(pl)
        else:
            pf = os.path.join(os.path.dirname(sf), "plan.md")
            pl = spec.rsplit("/", 1)[0] + "/plan.md" if "/" in spec else "plan.md"
        if not os.path.isfile(pf):
            return
        pr, sr = self.hdr_num(pf, "spec-rev"), self.hdr_num(sf, "rev")
        if pr and sr and pr != sr:
            print(f"note: plan {pl} pins spec-rev {pr}, spec is now rev {sr} — re-plan (set-plan refuses a stale spec-rev).",
                  file=sys.stderr)

    def plan_kind(self, path):
        if path.rsplit("/", 1)[-1] == "task.md":
            if self.task.get("route") != "light":
                self.err(f"{self.sub}: task.md is the light-route artifact; the full route records plan.md (or: "
                         f"claudehut-state set-route light).")
            return "task"
        return "plan"

    @staticmethod
    def plan_hash(path):
        try:
            with open(path, "rb") as f:
                return hashlib.sha1(f.read()).hexdigest()
        except OSError:
            return ""

    # ── task lifecycle helpers ───────────────────────────────────────────────────────────────────────────────
    def finished_kind(self):
        t = self.task or {}
        if t.get("phase") == "learn" or t.get("review") == "pass":
            return "done"
        if alt(t.get("findings_path"), "") != "":
            return "findings"
        return ""

    def own_evidence(self):
        ev = self.flag("--evidence")
        if not ev:
            return False
        return self.canon_path(ev).startswith(self.canon_path(self.task_dir()) + "/")

    def new_request_verb(self, fk):
        ph = self.arg0()
        sub = self.sub
        if sub in ("set-reuse-scan", "set-brainstorm", "set-spec", "set-plan", "set-plan-review", "set-enforcement",
                   "set-complexity", "set-profile", "set-route"):
            return True
        if sub == "set-phase":
            if ph == "learn":
                return False
            if ph == "review":
                return fk == "done"
            return True
        if sub == "set-outstanding":
            return fk == "done"
        if sub == "set-review":
            if ph == "pass" and self.own_evidence():
                return False
            if fk == "done":
                return True
            return ph == "pass"
        return False

    def supersede_active(self, by):
        if not self.task:
            return
        st = "done" if self.finished_kind() else "superseded"
        t = dict(self.task)
        t["status"] = st
        t["superseded_by"] = by
        t["ended"] = self.ts
        self.write_atomic(self.tfile, t)
        self.note(f"task {self.active} {'closed as done (it had finished) and ' if st == 'done' else ''}superseded by {by}")

    def claim_id(self, slug):
        nums = []
        try:
            for name in os.listdir(self.tasks_dir):
                m = re.match(r"^([0-9]+)-", name)
                if m:
                    nums.append(int(m.group(1)))
        except OSError:
            pass
        n = (max(nums) if nums else 0) + 1
        while True:
            tid = "%04d-%s" % (n, slug)
            try:
                os.mkdir(os.path.join(self.tasks_dir, tid))
                return tid
            except OSError:
                if not os.path.isdir(os.path.join(self.tasks_dir, tid)):
                    self.err(f"start: cannot create {self.tasks_dir}/{tid}")
                n += 1

    @staticmethod
    def git(repo, *args):
        try:
            r = subprocess.run(["git", "-C", repo] + list(args), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        except OSError:
            return None
        return r.stdout.decode("utf-8", "replace") if r.returncode == 0 else None

    def dirty(self, repo):
        try:
            r = subprocess.run(["git", "-C", repo, "-c", "core.quotePath=false", "status", "--porcelain=v1", "-z",
                                "--untracked-files=all"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
            raw = r.stdout.decode("utf-8", "replace")
        except OSError:
            raw = ""
        recs = raw.split("\0")
        out = []
        i = 0
        while i < len(recs):
            rec = recs[i]
            i += 1
            if rec[:2][:1] in ("R", "C") or rec[1:2] in ("R", "C"):
                i += 1   # a rename/copy record is followed by its origin path
            path = rec[3:]
            if not path or path.startswith((".claude/claudehut/", ".claudehut/")):
                continue
            out.append(path)
        return out

    def new_task(self, tid, route, profile, repos, cross):
        pabs = os.path.realpath(self.project)
        base, dirty = {}, {}
        for r in repos:
            r = r if r.startswith("/") else f"{self.project}/{r}"
            if not os.path.isdir(r):
                self.err(f"start: --repo {r} is not a directory")
            rabs = os.path.realpath(r)
            key = "." if rabs == pabs else rabs[len(pabs) + 1:] if rabs.startswith(pabs + "/") else rabs
            sha = (self.git(rabs, "rev-parse", "--short", "HEAD") or "").strip()
            base[key] = sha or None
            dirty[key] = self.dirty(rabs)
        rec = {"schema": 2, "id": tid, "route": route, "profile": profile or None, "phase": "discover",
               "plan_approved": False, "review": "pending", "plan_review_round": 0, "doc_schema": 2,
               "base": base, "pre_dirty": dirty, "scope": ["src/main/*", "*/src/main/*"], "enforcement_set": [],
               "status": "active", "session": self.session, "created": self.ts}
        if cross:
            rec["cross_service"] = True
        self.write_atomic(os.path.join(self.tasks_dir, tid, "task.json"), rec)
        self.supersede_active(tid)
        self.set_pointer(tid)

    # ── main ─────────────────────────────────────────────────────────────────────────────────────────────────
    def run(self):
        if self.args and self.args[0] == "cost-report":
            self.legacy()   # read-only ledger report: the bash writer's code path, unchanged
        if not self.args:
            self.err("a verb is required (start, set-phase, end, status, …)")
        self.sub = sub = self.args[0]
        self.shift_args = self.args[1:]
        if sub == "set-bypass":
            self.note("set-bypass was removed in v0.12 and did nothing: hooks are advisory; the set-* verbs refuse only "
                      "what their checks fail, and each refusal names its way out (for set-plan on a sensitive, "
                      "migration-profile or ≥5-task full-route plan: a plan-reviewer APPROVE, or claudehut-state "
                      "set-route light).")
            return 0
        if sub == "mark-skill":
            self.note("mark-skill was removed in v0.12 and did nothing: there is no skill rail.")
            return 0
        if sub in ("pause", "rename", "route"):
            self.note(f"{sub} was removed in v0.12 and did nothing.")
            return 0
        if sub not in VERBS:
            self.err(f"unknown verb: {sub}")

        self.root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
        self.project = os.environ.get("CLAUDE_PROJECT_DIR") or os.environ.get("PWD") or os.getcwd()
        self.plane = plane.plane_dir(self.project)
        self.plane_rel = plane.PLANE_NEW if os.path.basename(self.plane) == plane.PLANE_NEW else plane.PLANE_LEGACY
        self.state_dir = os.path.join(self.plane, "state")
        self.tasks_dir = os.path.join(self.plane, "tasks")

        self.session = self.session or os.environ.get("CLAUDEHUT_SESSION_ID") or ""
        if not self.session:
            self.err("no session id: pass --session <sid> or export CLAUDEHUT_SESSION_ID (SessionStart writes it; the "
                     "context line 'Session id:' carries it too)." + self._recent_sessions())
        if not SESSION_RE.match(self.session):
            self.err(f"invalid session id: {self.session}")
        self.file = os.path.join(self.state_dir, f"{self.session}.json")
        self.ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

        self.load()
        if sub == "status":
            return self.status()
        needs_task = sub not in ("start", "resume")
        if not self.task and needs_task and not (sub == "end" and self.foreign):
            self.no_task_note()
            return 0
        os.makedirs(self.state_dir, exist_ok=True)
        self.acquire_lock()
        try:
            self.load()
            return self.locked()
        finally:
            self.release_lock()

    def _recent_sessions(self):
        try:
            files = [os.path.join(self.state_dir, f) for f in os.listdir(self.state_dir) if f.endswith(".json")]
        except OSError:
            return ""
        files.sort(key=lambda p: os.stat(p).st_mtime if os.path.exists(p) else 0, reverse=True)
        recent = []
        for f in files:
            b = os.path.basename(f)[:-5]
            if "." in b or not b:
                continue
            d = read_json(f)
            if not (isinstance(d, dict) and d.get("schema") == 2 and "active_task" in d):
                continue
            recent.append(b)
            if len(recent) >= 5:
                break
        return f" Recent sessions: {' '.join(recent)} " if recent else ""

    def no_task_note(self, why=None):
        if self.foreign:
            self.note(f"task {self.foreign} is owned by session {self.foreign_owner} (it was resumed there) — "
                      f"'{self.sub}' recorded nothing for session {self.session} (to continue it here: claudehut-state "
                      f"resume {self.foreign}; a new request: claudehut-state start).")
        else:
            tail = why if why is not None else (" (open the task first: claudehut-state start --route light|full "
                                                 "--profile <p> --slug <s>)")
            self.note(f"no active task for session {self.session} — '{self.sub}' recorded nothing{tail}.")

    def status(self):
        out = {"schema": 2, "session": self.session, "active_task": self.active or None, "task": None}
        if self.task is not None:
            t = self.task
            keys = ("id", "route", "profile", "phase", "plan_approved", "review", "plan_review_round", "doc_schema",
                    "status", "scope")
            sel = {k: t.get(k) for k in keys}
            sel["enforcement_set"] = alt(t.get("enforcement_set"), [])
            for k in ("outstanding", "reuse_scan_artifact", "brainstorm_path", "spec_path", "plan_path",
                      "plan_review_evidence", "plan_review_user_decision", "review_evidence", "findings_path"):
                sel[k] = t.get(k)
            out["task"] = sel
        if self.legacy_state:
            out["legacy_state_ignored"] = True
        if self.foreign:
            out["resumed_elsewhere"] = {"task": self.foreign, "session": self.foreign_owner}
        print(dumps(out))
        return 0

    def locked(self):
        sub = self.sub
        if not self.task and sub not in ("start", "resume"):
            if sub == "end" and self.foreign:
                self.set_pointer("")
                self.note(f"end: task {self.foreign} is owned by session {self.foreign_owner}; only this session's "
                          f"pointer was cleared")
                return 0
            self.no_task_note(" (the task closed or moved to another session while waiting for the lock)")
            return 0
        if self.task:
            fk = self.finished_kind()
            if fk and self.new_request_verb(fk):
                a0 = f" {self.arg0()}" if self.arg0() else ""
                fnote = ", findings recorded" if fk == "findings" else ""
                self.note(f"task {self.active} is already finished (phase {self._jqr(self.task.get('phase'))}, review "
                          f"{self._jqr(self.task.get('review'))}{fnote}) — '{sub}{a0}' recorded nothing. A new request, "
                          f"or a change of profile/route, gets its own task: claudehut-state start --route light|full "
                          f"--profile <p> --slug <s> (it closes this one as done).")
                return 0
        handler = getattr(self, "v_" + sub.replace("-", "_"))
        rc = handler()
        if rc is not None:
            return rc
        self.task["updated"] = self.ts
        self.write_atomic(self.tfile, self.task)
        self.note(f"{sub} -> {self.tfile}")
        return 0

    @staticmethod
    def _jqr(v):
        """jq -r rendering of a scalar."""
        if v is None:
            return "null"
        if v is True:
            return "true"
        if v is False:
            return "false"
        return v if isinstance(v, str) else dumps(v)

    # ── verbs: each returns None (stamp `updated`, write task.json) or an exit code (it wrote what it needed) ──
    def v_start(self):
        route, slug, profile = self.flag("--route"), self.flag("--slug"), self.flag("--profile")
        if route not in ("light", "full"):
            self.err("start needs --route light|full (the direct route opens no task)")
        if not slug:
            self.err("start needs --slug <short-name> (it names tasks/NNNN-<slug>/)")
        b = slug.translate(str.maketrans("ABCDEFGHIJKLMNOPQRSTUVWXYZ", "abcdefghijklmnopqrstuvwxyz")).encode("utf-8")
        s = "".join(chr(c) if (97 <= c <= 122 or 48 <= c <= 57 or c == 45) else "-" for c in b)
        s = re.sub(r"--*", "-", s)
        s = re.sub(r"^-", "", s)
        s = re.sub(r"-$", "", s)[:48]
        slug = s
        if not slug:
            self.err("start: --slug has no usable characters (a-z, 0-9, -)")
        if profile not in ("",) + PROFILES:
            self.err(f"start: --profile must be feature|bugfix|audit|migration|investigation (got: {profile})")
        sa = self.shift_args
        repos = [sa[i + 1] if i + 1 < len(sa) else "" for i, a in enumerate(sa) if a == "--repo"]
        if not repos:
            repos = [self.project]
        for r in repos:
            r = r if r.startswith("/") else f"{self.project}/{r}"
            if not os.path.isdir(r):
                self.err(f"start: --repo {r} is not a directory")
        tops = []
        for r in repos:
            r = r if r.startswith("/") else f"{self.project}/{r}"
            t = (self.git(r, "rev-parse", "--show-toplevel") or "").strip() or os.path.realpath(r)
            t = os.path.realpath(t) if os.path.isdir(t) else t
            if t not in tops:
                tops.append(t)
        cross = len(tops) >= 2
        ws_plane = os.path.isdir(os.path.join(self.plane, "hub")) or self.git(self.project, "rev-parse", "--git-dir") is None
        if ws_plane and not cross:
            self.note("placement: this is the workspace/hub plane, which holds only cross-service tasks — a task in one "
                      "service belongs to that service's session (open Claude Code in the service repo and start it "
                      "there); for a cross-service task pass one --repo per service")
        elif not ws_plane and cross:
            self.note(f"placement: cross-service task ({len(tops)} repos) recorded in this service's plane with a base "
                      f"per repo; a session at the workspace/hub is where cross-service tasks normally live")
        os.makedirs(self.tasks_dir, exist_ok=True)
        tid = self.claim_id(slug)
        self.new_task(tid, route, profile, repos, cross)
        self.note(f"start -> {self.tasks_dir}/{tid}/task.json ({route}{', ' + profile if profile else ''}); write every "
                  f"artifact of this task into that dir")
        sys.stdout.write(f"{tid}\n{self.plane_rel}/tasks/{tid}/\n")
        return 0

    def v_resume(self):
        tid = self.arg0()
        if not tid or tid.startswith(".") or not ID_RE.match(tid):
            self.err("resume needs a task id (tasks/<id>/)")
        rf = os.path.join(self.tasks_dir, tid, "task.json")
        rt = read_json(rf)
        if not (isinstance(rt, dict) and rt.get("schema") == 2):
            self.err(f"resume: {rf} is missing or not a schema-2 task (v0.11 tasks cannot be resumed; start a new one "
                     f"and link the old artifacts)")
        st = self._jqr(alt(rt.get("status"), "active"))
        if st in ("done", "abandoned"):
            self.err(f"resume: task {tid} is {st}; start a new task instead")
        if self.task and self.active != tid:
            self.supersede_active(tid)
        nt = dict(rt)
        nt["status"] = "active"
        nt["session"] = self.session
        nt.pop("superseded_by", None)
        nt.pop("ended", None)
        self.write_atomic(rf, nt)
        self.set_pointer(tid)
        po = alt(rt.get("session"), "")
        po = po if isinstance(po, str) else ""
        if po and po != self.session and SESSION_RE.match(po):
            pf = os.path.join(self.state_dir, f"{po}.json")
            pd = read_json(pf)
            if isinstance(pd, dict) and pd.get("schema") == 2 and alt(pd.get("active_task"), "") == tid:
                self.write_atomic(pf, {"schema": 2, "active_task": None})
        self.note(f"resume -> {rf}")
        return 0

    def v_end(self):
        es = self.flag("--status")
        if es not in ("done", "abandoned"):
            self.err("end needs --status done|abandoned")
        self.gate_call("end", status=es)
        self.task["status"] = es
        self.task["ended"] = self.ts
        self.write_atomic(self.tfile, self.task)
        self.set_pointer("")
        self.note(f"end -> {self.tfile} ({es})")
        return 0

    def v_set_route(self):
        r = self.arg0()
        if r not in ("light", "full"):
            self.err("set-route needs light|full")
        self.task["route"] = r

    def v_set_phase(self):
        phase = self.arg0()
        if phase not in PHASES:
            self.err(f"invalid phase: {phase}")
        t = self.flag("--task")
        if t and t != self.active:
            self.note(f"set-phase: --task {t} ignored; the phase is recorded on the open task {self.active} (to switch "
                      f"tasks: claudehut-state resume {t})")
        self.task["phase"] = phase
        sp = self.flag("--spec")
        if sp:
            self.canon(sp)
            self.doclint_gate("spec", sp)
            self.task["spec_path"] = sp
        pl = self.flag("--plan")
        if pl:
            self.canon(pl)
            pk = self.plan_kind(pl)
            self.doclint_gate(pk, pl)
            self.task["plan_path"] = pl

    def v_set_reuse_scan(self):
        a = self.flag("--artifact")
        if not a:
            self.err(f"set-reuse-scan needs --artifact <path under {self.plane_rel}/tasks/NNNN-slug/>")
        self.canon(a)
        self.tmpl(a, r"^\|.*[Ff]it.*[Ii]mpact",
                  f"reuse-scan rejected: missing the Fit/Impact columns in {a} (legacy format?). Use "
                  f"skills/discover/references/reuse-scan-template.md — | Dimension | Existing asset | Decision | Fit | "
                  f"Impact | Effort | — and re-run set-reuse-scan.")
        self.tmpl(a, r"adopt|extend|reuse|framework|drop|[Nn]ew",
                  f"reuse-scan rejected: no reuse DECISION token in {a} (adopt/extend/reuse/framework/drop/new). State "
                  f"the decision per the template and re-run.")
        self.task["reuse_scan"] = True
        self.task["reuse_scan_artifact"] = a

    def v_set_brainstorm(self):
        p = self.arg0()
        if not p:
            self.err("set-brainstorm needs <path>")
        self.canon(p)
        self.doclint_gate("brainstorm", p)
        self.task["brainstorm_path"] = p

    def v_set_complexity(self):
        c = self.arg0()
        if c in ("trivial", "small"):
            nr = "light"
        elif c == "full":
            nr = "full"
        else:
            self.note("set-complexity: expected trivial|small|full, recorded nothing")
            return 0
        self.note(f"set-complexity is deprecated (v0.12 route): {c} → set-route {nr} on the open task {self.active}")
        self.task["route"] = nr

    def v_set_profile(self):
        pf = self.arg0()
        if pf not in PROFILES:
            self.err(f"set-profile needs feature|bugfix|audit|migration|investigation (got: {pf})")
        self.task["profile"] = pf

    def v_set_enforcement(self):
        sk, ru = self.flag("--skills"), self.flag("--rules")
        self.task["enforcement_set"] = [x for x in sk.split(",") + ru.split(",") if x]

    def v_set_spec(self):
        p = self.arg0()
        if not p:
            self.err("set-spec needs <path>")
        self.canon(p)
        self.doclint_gate("spec", p)
        self.task["spec_path"] = p
        self.spec_rev_note(p)

    def v_set_plan(self):
        p = self.arg0()
        if not p:
            self.err("set-plan needs <path>")
        self.canon(p)
        pk = self.plan_kind(p)
        self.doclint_gate(pk, p)
        pp = self.abspath(p)
        if self.task.get("route") == "full":
            # Smart gate (06 §8, AC12): a substantial (≥5 T-rows), sensitive (a T-row's Files cell — the 3rd column —
            # names a sensitive path) or migration-profile full-route plan needs a fresh plan-review APPROVE of these
            # exact bytes. Prose is not scanned. The way out is set-route light.
            lines = file_lines(pp)
            nrows = sum(1 for line in lines if re.match(r"^\| *T-[0-9]", line))
            sensitive = False
            for line in lines:
                cells = line.split("|")
                if len(cells) > 1 and re.match(SP + r"*T-[0-9]", cells[1]):
                    files_cell = cells[3] if len(cells) > 3 else ""
                    if re.search(r"security|/auth|auth/|migration|flyway|liquibase|changelog|password|secret|credential|"
                                 r"owasp|permitall|deserial", files_cell, re.I):
                        sensitive = True
            mig = alt(self.task.get("profile"), "") == "migration"
            if nrows >= 5 or sensitive or mig:
                pr = alt(self.task.get("plan_review"), "")
                if pr != "APPROVE":
                    self.err(f"set-plan: this full-route plan ({nrows} tasks{', sensitive path in Files' if sensitive else ''}"
                             f"{', profile migration' if mig else ''}) needs a plan-reviewer APPROVE first: dispatch "
                             f"claudehut:claudehut-plan-reviewer (it writes tasks/NNNN-<slug>/plan-review.md), then "
                             f"claudehut-state set-plan-review APPROVE --evidence <that path>. If this task does not need "
                             f"the full route: claudehut-state set-route light.")
                sh = alt(self.task.get("plan_review_plan_hash"), "")
                if sh:
                    ch = self.plan_hash(pp)
                    if ch and ch != sh:
                        self.err(f"set-plan: {p} differs from the plan that was reviewed (content hash mismatch). "
                                 f"Re-dispatch claudehut:claudehut-plan-reviewer and re-record set-plan-review APPROVE "
                                 f"before set-plan.")
        self.task["plan_path"] = p
        self.task["plan_approved"] = True

    def v_set_plan_review(self):
        v = self.arg0()
        if v not in ("APPROVE", "REVISE"):
            self.err("set-plan-review needs APPROVE|REVISE")
        ud = self.flag("--user-decision")
        rnd = alt(self.task.get("plan_review_round"), 0)
        rnd = self._jqr(rnd)
        rnd = int(rnd) if re.match(r"^[0-9]+$", rnd) else 0
        last = alt(self.task.get("plan_review"), "")
        capped = rnd >= 2 and last == "REVISE"
        if capped and not ud:
            self.err(f"set-plan-review: capped — plan review has run {rnd} rounds and the last verdict was REVISE (cap 2). "
                     f"Ask the user how to proceed (AskUserQuestion), then record their answer: claudehut-state "
                     f"set-plan-review APPROVE|REVISE --user-decision \"<the user's decision>\".")
        if ud and not capped:
            self.note(f"set-plan-review: --user-decision ignored — the review is not capped (round {rnd})")
            ud = ""
        ev = self.flag("--evidence") or f"{self.plane_rel}/tasks/{self.active}/plan-review.md"
        self.canon(ev)
        evp = self.abspath(ev)
        if not os.path.isfile(evp):
            self.err(f"set-plan-review: evidence file not found at {ev} — the plan-reviewer writes its verdict to "
                     f"plan-review.md before this is recorded.")
        self.doclint_gate("plan-review", ev)
        fv = ""
        vrx = re.compile(r"^" + SP + r"*[*]*" + SP + r"*Verdict" + SP + r"*[*]*" + SP + r"*:")
        for line in file_lines(evp):
            if vrx.match(line):
                rest = re.sub(r"^" + SP + r"*[*]*" + SP + r"*Verdict" + SP + r"*[*]*" + SP + r"*:" + SP + r"*", "", line, 1)
                rest = rest.replace("*", "").replace("`", "")
                parts = rest.split()
                fv = parts[0].upper() if parts else ""
                break
        if fv != v:
            if not ud:
                self.err(f"set-plan-review: {ev} says 'Verdict: {fv or '<none>'}' but {v} was given — record the "
                         f"reviewer's verdict as written (only the plan-reviewer writes plan-review.md).")
            self.note(f"set-plan-review: recording {v} over the file's Verdict {fv or '<none>'} on the user's decision")
        self.task["plan_review_evidence"] = ev
        if v == "APPROVE":
            planf = os.path.join(os.path.dirname(evp), "plan.md")
            if os.path.isfile(planf):
                self.task["plan_review_plan_hash"] = self.plan_hash(planf)
        if ud:
            self.task["plan_review"] = v
            self.task["plan_review_user_decision"] = ud
            self.task["plan_review_user_decision_at"] = self.ts
            self.task["plan_review_round"] = 0
        else:
            self.task["plan_review"] = v
            prr = alt(self.task.get("plan_review_round"), 0)
            self.task["plan_review_round"] = (prr if isinstance(prr, (int, float)) and not isinstance(prr, bool) else 0) + 1
            if v != "APPROVE" and rnd + 1 >= 2:
                self.note(f"set-plan-review: round {rnd + 1} of 2 ended REVISE — the cap is reached. Ask the user how to "
                          f"proceed (AskUserQuestion); the next set-plan-review needs --user-decision \"<their decision>\".")

    def v_set_review(self):
        r = self.arg0()
        if r not in ("pass", "pending", "capped"):
            self.err("set-review needs pass|pending|capped")
        if r == "pass":
            ev = self.flag("--evidence")
            if not ev:
                self.err("set-review pass requires --evidence <tasks/NNNN-slug/review.md> (the review artifact with the "
                         "coverage table + test summary).")
            self.canon(ev)
            evp = self.abspath(ev)
            if not os.path.isfile(evp):
                self.err(f"set-review pass: evidence file not found at {ev} — write review.md (merged coverage table + "
                         f"test evidence) before passing.")
            lines = file_lines(evp)
            if not any(re.search(r"^" + SP + r"*\|.*(✓|✗|satisfied|violated|n-?/?a)", ln, re.I) for ln in lines):
                self.err(f"set-review pass: {ev} has no coverage table — expected markdown rows like '| <item> | ✓ "
                         f"satisfied | file:line |'.")
            if not any(re.search(r"(gradlew|mvnw|gradle (test|build|check)|mvn (test|verify|install)|tests? run[: ]|"
                                 r"build success|[0-9]+ +(passed|passing|tests?))", ln, re.I) for ln in lines):
                self.err(f"set-review pass: {ev} shows no fresh test evidence (a build command + pass count, e.g. "
                         f"'./gradlew test — 12 passed').")
            locus = re.compile(r"\.(java|kt|kts|ts|tsx|js|jsx|py|go|rb|sql|md|yaml|yml|xml|gradle|sh|properties)\b|"
                               r"[A-Za-z0-9_]+Test\b|[A-Za-z0-9_]+#[A-Za-z0-9_]+")
            sat = [ln for ln in lines if re.search(r"^" + SP + r"*\|.*(✓|satisfied)", ln, re.I)]
            if any(not locus.search(ln) for ln in sat):
                self.err(f"set-review pass: a '✓ satisfied' coverage row in {ev} has no evidence locus. Cite WHERE each "
                         f"item is satisfied (Foo.java:42, a Test class, or Class#method).")
            # reuse-suspect loop gate: every suspect lint-reuse staged for THIS task needs a resolution token.
            sus = os.path.join(self.state_dir, f"{self.active}.suspects.jsonl")
            if os.path.isfile(sus) and os.path.getsize(sus) > 0:
                files = set()
                for raw in file_lines(sus):
                    if not raw.strip():
                        continue
                    try:
                        o = json.loads(raw)
                    except ValueError:
                        break   # jq stops at the first unparsable line (what it printed before still counts)
                    if not isinstance(o, dict) and o is not None:
                        break   # `.file` on a non-object is a jq error too
                    f = alt(o.get("file") if isinstance(o, dict) else None, None)
                    if f is not None:
                        files.add(f if isinstance(f, str) else dumps(f))
                res = re.compile(r"resolved|extracted|adopted|reused|de-?dup|false[ -]?positive|n-?/?a *[:-] *[^ ]", re.I)
                miss = ""
                for sfile in sorted(files):
                    if not sfile:
                        continue
                    if not any(sfile in ln and res.search(ln) for ln in lines):
                        miss += f" {sfile}"
                if miss:
                    self.err(f"set-review pass: lint-reuse staged reuse-suspect(s) [{miss} ] not RESOLVED in {ev} — each "
                             f"suspect's coverage row must carry a resolution token (resolved | extracted-util | "
                             f"adopted-commons | reused | false-positive:<reason>).")
            kout = self.gate_call("review-pass", evidence=evp)
            kb = kout.get("binding") if isinstance(kout, dict) else None
            if kb is not None and kb is not False and kb != "":
                self.task["review_binding"] = kb
            self.task["review_evidence"] = ev
        self.task["review"] = r

    def v_set_outstanding(self):
        j = self.arg0() or "[]"
        try:
            v = json.loads(j)
        except ValueError:
            v = None
        if not isinstance(v, list):
            self.err("set-outstanding needs a JSON array")
        self.task["outstanding"] = v

    def v_set_findings(self):
        p = self.arg0()
        if not p:
            self.err("set-findings needs <path>")
        self.canon(p)
        self.tmpl(p, r"^#", f"findings rejected: {p} has no headings — write the conclusions + file:line evidence as a "
                            f"structured findings report, then re-run set-findings.")
        self.task["findings_path"] = p

    def v_status(self):   # dispatched before the lock; kept for the handler table
        return self.status()

    def v_cost_report(self):
        self.legacy()


def main(argv, legacy):
    st = State(argv, legacy)
    try:
        return st.run()
    except Exit as e:
        return e.code
