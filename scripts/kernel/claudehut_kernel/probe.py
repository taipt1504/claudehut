"""Host adapter capability probe (K5, docs/v0.20/04-kernel-control.md §5.1).

Open-world facts about the host the harness runs in, written to <plane>/state/env-profile.json:
  - foreign PreToolUse hooks on Bash and whether they REWRITE the command (tested empirically, not by name):
    worktree-isolated subagents refuse a command whose input a hook changed (ENV-1: 1,031 refusals, 581 from
    `rtk git`). A rewritten command also breaks raw evidence (ACI-2: rtk's "Files are identical").
  - auth mode (plan | api | cloud provider), for the runner and eval (ADR K-17).

Testing a hook means running its command once with a synthetic PreToolUse payload, exactly what the host does
before every Bash call. It runs off the SessionStart critical path (maintain.sh, async) under an overall deadline
of 2 s; a timed-out hook's process group is killed. Results are cached per hook (command, plus the project for a
relative command) for a day, written after EACH hook. Hooks the user disabled (disableAllHooks, or non-managed hooks
under allowManagedHooksOnly) are never run. CLAUDEHUT_PROBE_HOOKS=0 disables execution entirely.
"""
import hashlib
import json
import os
import re
import signal
import subprocess
import time

SAMPLES = ("git status", "ls")
CACHE_TTL = 86400
DEADLINE = 2.0


def _read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def settings_sources(project_dir):
    home = os.path.expanduser("~")
    out = [("user", os.path.join(home, ".claude", "settings.json")),
           ("project", os.path.join(project_dir, ".claude", "settings.json")),
           ("local", os.path.join(project_dir, ".claude", "settings.local.json"))]
    for managed in ("/Library/Application Support/ClaudeCode/managed-settings.json",
                    "/etc/claude-code/managed-settings.json"):
        out.append(("managed", managed))
    return out


def _matches_bash(matcher):
    if matcher in (None, "", "*"):
        return True
    try:
        return re.fullmatch(matcher, "Bash") is not None
    except re.error:
        return "Bash" in matcher


def foreign_bash_hooks(project_dir):
    hooks = []
    sources = [(scope, path, _read(path)) for scope, path in settings_sources(project_dir)]
    sources = [(sc, p, d) for sc, p, d in sources if isinstance(d, dict)]
    if any(d.get("disableAllHooks") is True for _, _, d in sources):
        return []
    managed_only = any(d.get("allowManagedHooksOnly") is True for sc, _, d in sources if sc == "managed")
    for scope, path, data in sources:
        if managed_only and scope != "managed":
            continue
        for entry in (data.get("hooks") or {}).get("PreToolUse") or []:
            if not isinstance(entry, dict) or not _matches_bash(entry.get("matcher")):
                continue
            for h in entry.get("hooks") or []:
                cmd = (h or {}).get("command") if isinstance(h, dict) else None
                if not cmd or (h.get("type") not in (None, "command")):
                    continue
                if "claudehut" in cmd or "CLAUDE_PLUGIN_ROOT" in cmd:
                    continue
                hooks.append({"scope": scope, "source": path, "command": cmd})
    return hooks


def _cache_path():
    base = os.environ.get("CLAUDE_PLUGIN_DATA") or os.path.join(os.path.expanduser("~"), ".claude", "plugins", "data",
                                                                    "claudehut-claudehut")
    return os.path.join(base, "host-probe-cache.json")


def _run_hook(cmd, payload, cwd, timeout):
    try:
        p = subprocess.Popen(cmd, shell=True, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                             cwd=cwd, start_new_session=True)
    except OSError:
        return None
    try:
        out, _ = p.communicate(payload.encode(), timeout=max(0.1, timeout))
        return out
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
        p.communicate()
        return None


def test_rewrite(cmd, cwd, deadline=None):
    """Run the hook with synthetic payloads; return {sample: rewritten_command} for each rewrite seen."""
    rewrites = {}
    for sample in SAMPLES:
        left = (deadline - time.time()) if deadline else 2.0
        if left <= 0:
            break
        payload = json.dumps({"hook_event_name": "PreToolUse", "tool_name": "Bash",
                              "tool_input": {"command": sample}, "cwd": cwd})
        raw = _run_hook(cmd, payload, cwd, left)
        if raw is None:
            continue
        try:
            out = json.loads(raw.decode("utf-8", "replace") or "{}")
        except ValueError:
            continue
        upd = ((out.get("hookSpecificOutput") or {}).get("updatedInput") or {}) if isinstance(out, dict) else {}
        new = upd.get("command") if isinstance(upd, dict) else None
        if new and new != sample:
            rewrites[sample] = new
    return rewrites


def _save_cache(cache_file, cache):
    try:
        os.makedirs(os.path.dirname(cache_file), exist_ok=True)
        tmp = f"{cache_file}.tmp.{os.getpid()}"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(cache, f)
        os.replace(tmp, cache_file)
    except OSError:
        pass


def auth_mode():
    env = os.environ
    for var, mode in (("CLAUDE_CODE_USE_BEDROCK", "bedrock"), ("CLAUDE_CODE_USE_VERTEX", "vertex"),
                      ("CLAUDE_CODE_USE_FOUNDRY", "foundry")):
        if env.get(var) in ("1", "true"):
            return mode
    if env.get("ANTHROPIC_API_KEY") or env.get("ANTHROPIC_AUTH_TOKEN"):
        return "api"
    return "plan"


def probe(project_dir, execute=True):
    cache_file = _cache_path()
    cache = _read(cache_file) or {}
    now = time.time()
    hooks = foreign_bash_hooks(project_dir)
    deadline = now + DEADLINE
    for h in hooks:
        cmd = h["command"]
        scope_key = cmd if cmd.lstrip().startswith("/") or "/" not in cmd.split()[0] else cmd + "\0" + project_dir
        key = hashlib.sha256(scope_key.encode()).hexdigest()[:16]
        hit = cache.get(key)
        if hit and now - hit.get("at", 0) < CACHE_TTL:
            h["rewrites"] = hit.get("rewrites", {})
            h["tested"] = True
            continue
        if not execute or time.time() >= deadline:
            h["tested"] = False
            continue
        h["rewrites"] = test_rewrite(cmd, project_dir, deadline)
        h["tested"] = True
        cache[key] = {"at": now, "rewrites": h["rewrites"]}
        _save_cache(cache_file, cache)
    rewriters = [h for h in hooks if h.get("rewrites")]
    return {"schema": 1, "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "auth_mode": auth_mode(),
            "bash_hooks": hooks, "rewriters": len(rewriters)}


def advice(profile):
    """One line for the SessionStart context when a hook rewrites Bash, else ''."""
    rw = [h for h in profile.get("bash_hooks", []) if h.get("rewrites")]
    if not rw:
        return ""
    h = rw[0]
    example = next(iter(h["rewrites"].items()))
    return (f"Host: a {h['scope']} PreToolUse hook (`{h['command']}`) rewrites Bash (`{example[0]}` → `{example[1]}`). "
            "Worktree-isolated agents refuse rewritten commands and rewritten output is not raw evidence: in worktrees "
            "and for verification call tools by absolute path (`/usr/bin/git`), one simple command per Bash call, "
            "edit files with Edit, not sed.")
