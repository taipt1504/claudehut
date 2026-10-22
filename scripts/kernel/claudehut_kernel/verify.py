"""claudehut-verify (K7, docs/v0.20/06-quality-plane.md §3): deterministic checks on review artifacts.

  claims    every `path` / `path:line` cited in a markdown artifact exists (and the line is in range)
  findings  no open finding: task.outstanding empty and no table row whose status cell says open
  binding   content fingerprint of the task's change + spec/plan hashes, stored at review pass
  verdict   the stored binding still matches the tree and the artifacts (else the verdict is stale)

Read-only on the repo; git is invoked without hooks or pagers. Output is written for the model to act on.
"""
import hashlib
import os
import re
import subprocess

from . import plane

EXT = (r"java|kt|kts|ts|tsx|js|jsx|mjs|py|go|rb|rs|sql|md|ya?ml|xml|gradle|sh|bash|properties|json|toml"
       r"|txt|conf|cfg|ini|html|css|proto|avsc|graphql")
# A path-like token with a known extension, optionally followed by :line or :line-line. The look-behind keeps
# us from starting mid-token (URLs, package names like io.f8a.Foo are excluded because they have no extension).
CLAIM_RE = re.compile(
    r"(?<![\w/.@~$-])((?:\.{0,2}/)?(?:[\w@.+-]+/)*[\w@+-][\w@.+-]*\.(?:" + EXT + r"))(?::(\d+)(?:\s*[-–]\s*(\d+))?)?(?![\w/])")
URL_RE = re.compile(r"[a-z][a-z0-9+.-]*://\S+", re.I)
DELETED_HINT = re.compile(r"\b(delet|remov|xo[áa]\b|rename|moved\b)", re.I)
# A path a line PROPOSES rather than cites ("add application-prod.yml later", "tạo file mới …") is not evidence.
FUTURE_HINT = re.compile(r"\b(add|create|new file|introduce|later|todo|t[ạa]o|th[êe]m)\b", re.I)
OPEN_CELL = re.compile(r"^\s*(open|opened|pending|todo|unresolved|chưa( xử lý| sửa)?|mở)\s*$", re.I)


def _git(repo, *args, binary=False):
    env = dict(os.environ, GIT_PAGER="cat", GIT_TERMINAL_PROMPT="0", LC_ALL="C")
    try:
        p = subprocess.run(["git", "-C", repo, "-c", "core.quotePath=false", "-c", "core.hooksPath=/dev/null", *args],
                           capture_output=True, env=env, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if p.returncode != 0:
        return None
    return p.stdout if binary else p.stdout.decode("utf-8", "replace")


class Repo:
    def __init__(self, key, path):
        self.key, self.path = key, path
        self._files = None

    def files(self):
        if self._files is None:
            out = _git(self.path, "ls-files", "-z", "--cached", "--others", "--exclude-standard") or ""
            self._files = [f for f in out.split("\0") if f]
        return self._files

    def by_basename(self, name):
        hits = [f for f in self.files() if f == name or f.endswith("/" + name)]
        return hits or self._claude_dir(name)

    def _claude_dir(self, name):
        """Rules, skills and agents often live in a gitignored .claude/: look there by basename too."""
        root = os.path.join(self.path, ".claude")
        out = []
        for d, dirs, fs in os.walk(root):
            dirs[:] = [x for x in dirs if x not in ("worktrees", "claudehut")]
            if name in fs:
                out.append(os.path.relpath(os.path.join(d, name), self.path))
        return out

    def by_suffix(self, rel):
        rel = _strip_dot_slash(rel)
        return [f for f in self.files() if f == rel or f.endswith("/" + rel)]

    def exists_at(self, sha, rel):
        return bool(sha) and _git(self.path, "cat-file", "-e", f"{sha}:{rel}") is not None


def _strip_dot_slash(p):
    while p.startswith("./"):
        p = p[2:]
    return p


def _line_count(path):
    try:
        with open(path, "rb") as f:
            return sum(1 for _ in f)
    except OSError:
        return None


TABLE_SEP = re.compile(r"^[ \t]*\|[ \t:|-]*-[ \t:|-]*\|[ \t]*$")

def extract_claims(text):
    """Yield (lineno, path, start, end, context_line) for each cited file outside URLs."""
    fenced = False
    lines = text.splitlines()
    for n, line in enumerate(lines, 1):
        if line.lstrip().startswith(("```", "~~~")):
            fenced = not fenced
            continue
        if fenced:  # stack traces and logs cite frames, not evidence
            continue
        if line.lstrip().startswith("|") and n < len(lines) and TABLE_SEP.match(lines[n]):
            continue  # a table header names columns (`File.java:NN "quote"`), it cites nothing
        scrub = URL_RE.sub(" ", line)
        for m in CLAIM_RE.finditer(scrub):
            path = m.group(1)
            if path.startswith(("http", "www.")):
                continue
            start = int(m.group(2)) if m.group(2) else None
            end = int(m.group(3)) if m.group(3) else None
            yield n, path, start, end, line


def check_claims(md_path, project_dir, repos, base=None):
    """Return (checked, problems). A problem is a dict with kind ∈ missing|line-out-of-range.

    Resolution order: relative to each repo root, relative to the project dir, then a unique suffix or basename
    match among the repo's tracked + untracked files. A path absent now but present at the task's base commit
    counts as deleted by the task (not a problem). Ambiguous basenames (≥2 matches) are not judged.
    """
    base = base or {}
    try:
        with open(md_path, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        return 0, [{"kind": "unreadable", "path": md_path, "fix": "the artifact itself cannot be read"}]
    objs = [Repo(k, p) for k, p in repos]
    md_dir = os.path.dirname(os.path.abspath(md_path))
    checked, problems, seen = 0, [], set()
    for lineno, path, start, end, ctx in extract_claims(text):
        key = (path, start, end)
        if key in seen:
            continue
        seen.add(key)
        checked += 1
        found = None
        candidates = []
        if os.path.isabs(path):
            candidates.append(path)
        else:
            for r in objs:
                candidates.append(os.path.join(r.path, path))
            candidates.append(os.path.join(project_dir, path))
            candidates.append(os.path.join(md_dir, path))
        for c in candidates:
            if os.path.isfile(c):
                found = c
                break
        if not found and not os.path.isabs(path):
            hits = []
            for r in objs:
                matches = r.by_suffix(path) if "/" in path else r.by_basename(path)
                hits.extend(os.path.join(r.path, h) for h in matches)
            hits = sorted(set(hits))
            if len(hits) == 1:
                found = hits[0]
            elif len(hits) > 1:
                continue  # ambiguous: do not judge
        if not found:
            rel = _strip_dot_slash(path)
            if (any(r.exists_at(base.get(r.key), rel) for r in objs) or DELETED_HINT.search(ctx) is not None
                    or FUTURE_HINT.search(ctx) is not None):
                continue  # deleted/renamed by the task, or explicitly described as gone
            problems.append({"kind": "missing", "path": path, "line": start, "at": f"{os.path.basename(md_path)}:{lineno}",
                             "fix": f"`{path}` does not exist in the working tree. Cite the file that holds the evidence "
                                    f"now, or mark the row as removed."})
            continue
        if start is not None:
            n = _line_count(found)
            last = end or start
            if n is not None and (start < 1 or last > n):
                problems.append({"kind": "line-out-of-range", "path": path, "line": start,
                                 "at": f"{os.path.basename(md_path)}:{lineno}",
                                 "fix": f"`{path}` has {n} lines; line {last} does not exist. Re-cite the current line."})
    return checked, problems


STATUS_HEADER = re.compile(r"^(status|state|trạng thái|tình trạng|resolution)$", re.I)


def _status_cells(text):
    """Yield (lineno, row_text, status_cell) for tables whose header has a Status-like column; other tables (domain
    states such as PENDING/OPEN) are never read as findings."""
    col, n_cols = None, 0
    for n, line in enumerate(text.splitlines(), 1):
        s = line.strip()
        if not (s.startswith("|") and s.endswith("|")):
            col = None
            continue
        cells = [c.strip() for c in s.strip("|").split("|")]
        if re.match(r"^\|[\s:|-]+\|$", s):
            continue
        if col is None:
            hits = [i for i, c in enumerate(cells) if STATUS_HEADER.match(c.strip("* "))]
            col = hits[0] if hits else -1
            n_cols = len(cells)
            continue
        if col >= 0 and len(cells) == n_cols:
            yield n, " | ".join(cells), cells[col]


def check_findings(task, review_md=None):
    problems = []
    out = task.get("outstanding") or []
    if isinstance(out, list) and out:
        problems.append({"kind": "outstanding", "items": out[:10],
                         "fix": "task.outstanding is not empty: resolve each item or record it as deferred with a reason "
                                "(claudehut-state set-outstanding '[]')."})
    if review_md and os.path.isfile(review_md):
        with open(review_md, encoding="utf-8", errors="replace") as f:
            text = f.read()
        for n, row, cell in _status_cells(text):
            if OPEN_CELL.match(cell):
                problems.append({"kind": "open-finding", "at": f"{os.path.basename(review_md)}:{n}",
                                 "row": row[:160],
                                 "fix": "a finding row is still open: fix it, or mark it deferred/accepted with a reason."})
    return problems


def _worktree_tree(path):
    """Tree sha of the working tree as `git add -A` would stage it, built in a throwaway index so the user's index is
    untouched. `.claude/` and `.claudehut/` are excluded: the plane (either layout, K-18), rules promoted by the Learn
    phase and settings change after review without changing the reviewed code. The same content gives the same tree whether it is untracked, staged or
    committed — so only a real edit changes it."""
    import shutil
    import tempfile
    gitdir = _git(path, "rev-parse", "--absolute-git-dir")
    if gitdir is None:
        return None
    tmpdir = tempfile.mkdtemp(prefix="claudehut-fp.")
    idx = os.path.join(tmpdir, "index")
    try:
        src = os.path.join(gitdir.strip(), "index")
        if os.path.isfile(src):
            shutil.copyfile(src, idx)
        env = dict(os.environ, GIT_INDEX_FILE=idx, GIT_PAGER="cat", GIT_TERMINAL_PROMPT="0", LC_ALL="C")
        base_cmd = ["git", "-C", path, "-c", "core.hooksPath=/dev/null"]
        try:
            add = subprocess.run(base_cmd + ["add", "-A", "--", ".", ":(exclude).claude", ":(exclude).claudehut"],
                                 capture_output=True, env=env,
                                 timeout=120)
            if add.returncode != 0:
                return None
            w = subprocess.run(base_cmd + ["write-tree"], capture_output=True, env=env, timeout=60)
        except (OSError, subprocess.TimeoutExpired):
            return None
        return w.stdout.decode().strip() if w.returncode == 0 else None
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def fingerprint(repos, base=None):
    """Per repo: the tree sha of the working tree (see _worktree_tree). Repos that are not git repos are skipped."""
    fp = {}
    for key, path in repos:
        t = _worktree_tree(path)
        if t:
            fp[key] = t
    return fp


def file_sha(path):
    if not path or not os.path.isfile(path):
        return None
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def binding(project_dir, task, ts):
    repos = plane.repo_dirs(project_dir, task)
    return {"at": ts, "fingerprint": fingerprint(repos, task.get("base") or {}),
            "spec_sha256": file_sha(plane.abspath(project_dir, task.get("spec_path"))),
            "plan_sha256": file_sha(plane.abspath(project_dir, task.get("plan_path")))}


def check_verdict(project_dir, task):
    """Problems when the stored review binding no longer matches. No binding (pre-0.12.7 task) → no judgement."""
    b = task.get("review_binding")
    if not isinstance(b, dict):
        return []
    problems = []
    now = binding(project_dir, task, b.get("at"))
    changed = sorted(k for k, v in (b.get("fingerprint") or {}).items() if now["fingerprint"].get(k) not in (None, v))
    if changed:
        problems.append({"kind": "tree-changed", "repos": changed,
                         "fix": "code changed after the review passed: re-run the review on the current tree "
                                "(claudehut-state set-review pass again), or end with --override and a reason."})
    for k, label in (("spec_sha256", "spec"), ("plan_sha256", "plan")):
        if b.get(k) and now.get(k) and b[k] != now[k]:
            problems.append({"kind": f"{label}-changed",
                             "fix": f"the {label} was revised after the review passed: re-review against the new {label}."})
    return problems
