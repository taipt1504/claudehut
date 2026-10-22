"""`claudehut-run` — the offline runner (docs/v0.20 09 §5 option B, Q1; ADR K-17 auth; M5d).

Jobs run without a person: eval suites, transcript mining, drift scans. Read-only by contract: a job reads the
projects and transcripts it is pointed at and writes ONLY its report directory (default: a temp dir, never a repo).
Questions it cannot ask a person go into the report.

Auth (09 §7) is independent of the job: `plan` = the subscription login (`claude -p`, never `--bare`: bare "doesn't
use your subscription login"), `api` = ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN or a cloud provider
(`claude --bare -p --plugin-dir <root>`, with a scratch CLAUDE_CONFIG_DIR so nothing lands in the user's config),
`auto` = api when such a credential is in the environment or an apiKeyHelper is configured (which also makes an
explicit `plan` an error: the CLI would bill the API), else plan. Model calls run from an empty dir under the report. Every report records auth_mode,
claude_version and the env-profile, and secrets are only ever printed as `<set>`.

Jobs:
  eval    the plugin's `claude plugin eval` suites through evals/plugin-eval.sh (a source checkout only: the
          distributed plugin ships no evals). Extra args pass through (--case, --runs, --ablation …).
  mining  tool errors in Claude Code transcripts (<projects-dir>/*/*.jsonl, default ~/.claude/projects), counted
          by class. Counts and classes only: no excerpt, no path, no project name leaves the scan. --summarize asks
          the model (in the chosen auth mode) for a short reading of the COUNTS.
  drift   per project: index freshness and vendor-leak findings (deterministic, no model).
"""
import glob
import json
import os
import re
import shutil
import subprocess
import tempfile
import time

from . import plane, status, vendorleak

KEY_VARS = ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN")
PROVIDER_VARS = ("CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY")
ERROR_CLASSES = (   # first match wins; the order puts the specific ahead of the generic
    ("worktree-refusal", r"outside (?:the|this) worktree|worktree.{0,40}refus|refus.{0,40}worktree"),
    ("zsh-glob", r"no matches found"),
    ("permission-denied", r"[Pp]ermission (?:for this command )?(?:was )?denied|Operation not permitted|EACCES"),
    ("hook-blocked", r"hook.{0,40}(?:block|denied)|blocked by .{0,20}hook"),
    ("gate-refused", r"refused by the invariant|gate \w+ BLOCKED"),
    ("state-cli", r"claudehut-state:"),
    ("edit-mismatch", r"String to replace not found|old_string .{0,30}not (?:found|unique)"),
    ("file-not-read", r"has not been read yet|[Rr]ead it first"),
    ("timeout", r"timed out|[Tt]imeout"),
    ("not-found", r"command not found|No such file or directory|ENOENT"),
)


def api_key_helper(env, project=None):
    """(scope, command) of an apiKeyHelper in the settings `claude` would load, else (None, None). 09 §7 counts it as
    an api credential: with one configured, a plain `claude -p` bills the API, not the plan."""
    user_dir = env.get("CLAUDE_CONFIG_DIR") or os.path.join(os.path.expanduser("~"), ".claude")
    srcs = [("user", os.path.join(user_dir, "settings.json"))]
    if project:
        srcs += [("project", os.path.join(project, ".claude", "settings.json")),
                 ("local", os.path.join(project, ".claude", "settings.local.json"))]
    srcs += [("managed", "/Library/Application Support/ClaudeCode/managed-settings.json"),
             ("managed", "/etc/claude-code/managed-settings.json")]
    for scope, path in srcs:
        d = plane.read_json(path)
        if isinstance(d, dict) and d.get("apiKeyHelper"):
            return scope, d["apiKeyHelper"]
    return None, None


def resolve_auth(want, env, project=None):
    """→ (mode, error). mode ∈ plan | api."""
    helper_scope, _ = api_key_helper(env, project)
    has_cred = (any(env.get(v) for v in KEY_VARS) or any(env.get(v) in ("1", "true") for v in PROVIDER_VARS)
                or bool(helper_scope))
    if want == "plan" and helper_scope:
        return None, (f"--auth plan: an apiKeyHelper is configured ({helper_scope} settings), so `claude -p` would "
                      f"bill the API and the report would be mislabelled. Use --auth api, or remove the helper")
    if want == "auto":
        return ("api" if has_cred else "plan"), None
    if want == "api" and not has_cred:
        return None, ("--auth api needs ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN or a provider "
                      "(CLAUDE_CODE_USE_BEDROCK/VERTEX/FOUNDRY) in the environment")
    if want not in ("plan", "api"):
        return None, "--auth must be plan|api|auto"
    return want, None


def child_env(mode, env, config_dir):
    e = dict(env)
    if mode == "plan":
        for v in KEY_VARS:   # a key in the environment would silently bill the API instead of the plan
            e.pop(v, None)
    else:
        e["CLAUDE_CONFIG_DIR"] = config_dir
    return e


def model_argv(mode, prompt, plugin_root, helper=None):
    if mode == "plan":
        return ["claude", "-p", prompt, "--output-format", "json"]
    argv = ["claude", "--bare", "-p", prompt, "--output-format", "json", "--plugin-dir", plugin_root]
    if helper:   # the scratch config dir does not carry the user's helper: pass the command (not a secret) along
        argv += ["--settings", json.dumps({"apiKeyHelper": helper})]
    return argv


def masked_env(env):
    """What a report or a dry run may show about credentials: presence only."""
    return {v: "<set>" for v in KEY_VARS + PROVIDER_VARS + ("CLAUDE_CONFIG_DIR",) if env.get(v)}


def claude_version(env, cwd=None):
    try:
        p = subprocess.run(["claude", "--version"], capture_output=True, text=True, env=env, timeout=20, cwd=cwd)
        return (p.stdout.strip().splitlines() or ["unknown"])[0]
    except (OSError, subprocess.TimeoutExpired):
        return "unavailable"


# ── jobs ────────────────────────────────────────────────────────────────────────────────────────────────────────
def mine(projects_dir, since_days=None, now=None):
    """Counts only. A transcript line is a JSON event; tool results flagged is_error are classified."""
    now = now or time.time()
    counts = {k: 0 for k, _ in ERROR_CLASSES}
    counts["other"] = 0
    files = sorted(glob.glob(os.path.join(projects_dir, "*", "*.jsonl")))
    tool_calls = errors = sessions = 0
    rx = [(k, re.compile(p)) for k, p in ERROR_CLASSES]
    for f in files:
        try:
            if since_days and now - os.stat(f).st_mtime > since_days * 86400:
                continue
            fh = open(f, encoding="utf-8", errors="replace")
        except OSError:
            continue
        sessions += 1
        with fh:
            for line in fh:
                if '"tool_use"' not in line and '"tool_result"' not in line:
                    continue
                try:
                    o = json.loads(line)
                except ValueError:
                    continue
                content = ((o.get("message") or {}).get("content")) if isinstance(o, dict) else None
                for c in content if isinstance(content, list) else []:
                    if not isinstance(c, dict):
                        continue
                    if c.get("type") == "tool_use":
                        tool_calls += 1
                    elif c.get("type") == "tool_result" and c.get("is_error"):
                        errors += 1
                        text = c.get("content")
                        text = text if isinstance(text, str) else json.dumps(text, ensure_ascii=False)
                        k = next((k for k, r in rx if r.search(text)), "other")
                        counts[k] += 1
    return {"sessions": sessions, "tool_calls": tool_calls, "tool_errors": errors,
            "error_rate": round(errors / tool_calls, 4) if tool_calls else 0.0, "by_class": counts}


def drift(projects):
    rows = []
    for i, p in enumerate(projects, 1):
        p = os.path.abspath(p)
        k = status.knowledge(p)
        vl = vendorleak.scan(p)
        rows.append({"project": f"project-{i}", "index": k["index"]["state"], "variation": k["index"]["variation"],
                     "vendor_findings": len(vl["findings"]), "vendors_known": len(vl["vendors"]),
                     "families": vl["families"]})
    return {"projects": rows}


def run(job, auth="auto", out=None, dry_run=False, extra=None, projects_dir=None, since_days=None, summarize=False,
        projects=None, plugin_root=None, env=None):
    """→ (rc, report). The report is also written to <out>/report.json unless dry_run."""
    env = dict(env if env is not None else os.environ)
    plugin_root = plugin_root or os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    mode, err = resolve_auth(auth, env, os.getcwd())
    if err:
        return 2, {"error": err}
    _, helper = api_key_helper(env, os.getcwd())
    out = out or os.path.join(tempfile.gettempdir(), "claudehut-run", f"{job}-{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}")
    config_dir = os.path.join(out, "claude-config")
    # Every model call runs from an empty dir under the report: from a repo it would load that repo's hooks (which
    # write its plane) and add a transcript under that project (which later mining would count).
    work = os.path.join(out, "cwd")
    cenv = child_env(mode, env, config_dir)
    rep = {"job": job, "auth_mode": mode, "requested_auth": auth, "env": masked_env(cenv), "dry_run": dry_run,
           "read_only": True, "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "questions": []}
    rc = 0
    if job == "eval":
        script = os.path.join(plugin_root, "evals", "plugin-eval.sh")
        argv = ["bash", script, "--auth", mode] + list(extra or [])
        rep["argv"] = argv
        if not os.path.isfile(script):
            return 2, dict(rep, error="eval needs a source checkout of the plugin (the distributed plugin ships no "
                                      "evals/): run claudehut-run from the repo")
        if not dry_run:
            os.makedirs(work, exist_ok=True)
            rep["claude_version"] = claude_version(cenv, work)
            p = subprocess.run(argv, env=cenv, capture_output=True, text=True, cwd=work)
            rc = p.returncode
            m = re.search(r"results: (\S+)", p.stdout or "")
            rep.update(exit=rc, results_dir=m.group(1) if m else None, tail=(p.stdout or "").strip().splitlines()[-3:])
    elif job == "mining":
        pd = projects_dir or os.path.join(os.path.expanduser("~"), ".claude", "projects")
        rep["mining"] = mine(pd, since_days)
        if summarize:
            prompt = ("Below are COUNTS of tool errors by class from Claude Code transcripts (no excerpts). In at most "
                      "5 bullet points, say which classes matter most and one plugin-side change worth testing for "
                      "each. Counts: " + json.dumps(rep["mining"]))
            argv = model_argv(mode, prompt, plugin_root, helper if mode == "api" else None)
            rep["argv"] = argv[:2] + ["<prompt: counts only>"] + argv[3:]
            if not dry_run:
                os.makedirs(work, exist_ok=True)
                rep["claude_version"] = claude_version(cenv, work)
                p = subprocess.run(argv, env=cenv, capture_output=True, text=True, timeout=600, cwd=work)
                rc = p.returncode
                try:
                    res = json.loads(p.stdout)
                    rep["summary"] = res.get("result")
                    rep["cost_usd_estimate"] = res.get("total_cost_usd")
                except ValueError:
                    rep["summary"] = None
                    rep["error"] = (p.stderr or "").strip()[-300:]
    elif job == "drift":
        if not projects:
            return 2, dict(rep, error="drift needs --project DIR (repeat)")
        rep["drift"] = drift(projects)
    else:
        return 2, dict(rep, error=f"unknown job {job} (eval | mining | drift)")
    prof = plane.read_json(os.path.join(plane.plane_dir(os.getcwd()), "state", "env-profile.json"), {}) or {}
    rep["env_profile"] = {"auth_mode": prof.get("auth_mode"), "rewriters": prof.get("rewriters")} if prof else None
    if not dry_run:
        os.makedirs(out, exist_ok=True)
        with open(os.path.join(out, "report.json"), "w", encoding="utf-8") as f:
            json.dump(rep, f, ensure_ascii=False, indent=1)
        rep["report"] = os.path.join(out, "report.json")
        for d in (config_dir, work):
            if os.path.isdir(d) and not os.listdir(d):
                shutil.rmtree(d, ignore_errors=True)
    return rc, rep
