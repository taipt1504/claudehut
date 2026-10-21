"""Liveness canaries (K7/K9, docs/v0.20/06-quality-plane.md §2, ADR K-06; problem VER-3).

Every control must prove it fires in the REAL runtime (this machine's shell, PATH, env and other plugins), not only
in a clean CI bash. The selftest runs in a throwaway plane:
  1. hook contract — every hook script in hooks/hooks.json, fed a synthetic payload for its event, exits 0 and
     prints at most one JSON object (ADR-H4);
  2. behavioural canaries — a known-bad input each control must catch:
       gate.end           block mode refuses `end --status done` with the review pending
       verify.claims      a cited file that does not exist is reported
       record-failure     a failed Bash call is recorded with its exit code and stderr (682/682 records were empty)
       probe              the host probe answers with an auth mode
A control that does not produce its expected result is DEAD and the selftest exits 1.
"""
import json
import os
import shutil
import subprocess
import tempfile

EVENT_PAYLOAD = {
    "SessionStart": {"source": "startup"},
    "UserPromptSubmit": {"prompt": "selftest"},
    "PreToolUse": {"tool_name": "Write", "tool_input": {"file_path": "x/Selftest.java", "content": "class A {}"}},
    "PostToolUse": {"tool_name": "Write", "tool_input": {"file_path": "x/Selftest.java"}, "tool_response": {}},
    "PostToolUseFailure": {"tool_name": "Bash", "tool_input": {"command": "false"},
                           "error": "Exit code 7\nselftest-stderr"},
    "SubagentStart": {"agent_id": "a-selftest", "agent_type": "claudehut-explorer"},
    "SubagentStop": {"agent_id": "a-selftest", "agent_type": "claudehut-explorer"},
    "InstructionsLoaded": {"file_path": ".claude/rules/x.md"},
}


def _json_objects(text):
    dec, i, n = json.JSONDecoder(), 0, 0
    text = text.strip()
    while i < len(text):
        while i < len(text) and text[i].isspace():
            i += 1
        if i >= len(text):
            break
        try:
            _, j = dec.raw_decode(text, i)
        except ValueError:
            return -1
        n, i = n + 1, j
    return n


def _plane(root):
    p = os.path.join(root, "proj")
    os.makedirs(os.path.join(p, ".claudehut", "tasks"))
    os.makedirs(os.path.join(p, ".claudehut", "state"))
    with open(os.path.join(p, ".claudehut", "topology.json"), "w") as f:
        json.dump({"schema": 1, "mode": "mono", "language": "en"}, f)
    subprocess.run(["git", "init", "-q", p], capture_output=True)
    return p


def _hook_commands(plugin_root):
    try:
        with open(os.path.join(plugin_root, "hooks", "hooks.json")) as f:
            hooks = json.load(f).get("hooks", {})
    except (OSError, ValueError):
        return []
    seen, out = set(), []
    for event, entries in hooks.items():
        for e in entries:
            for h in e.get("hooks", []):
                cmd = h.get("command", "")
                if cmd and (event, cmd) not in seen:
                    seen.add((event, cmd))
                    out.append((event, cmd))
    return out


def run(plugin_root):
    results = []
    tmp = tempfile.mkdtemp(prefix="claudehut-selftest.")
    try:
        proj = _plane(tmp)
        env = dict(os.environ, CLAUDE_PLUGIN_ROOT=plugin_root, CLAUDE_PROJECT_DIR=proj,
                   CLAUDE_PLUGIN_DATA=os.path.join(tmp, "data"), CLAUDEHUT_HOST_PROBE="0")
        for var in ("CLAUDE_ENV_FILE", "CLAUDEHUT_HUB", "CLAUDEHUT_FEDERATION_ROOT", "CLAUDEHUT_GATE_MODE",
                    "CLAUDEHUT_SESSION_ID"):
            env.pop(var, None)
        for event, cmd in _hook_commands(plugin_root):
            payload = dict(EVENT_PAYLOAD.get(event, {}), hook_event_name=event, session_id="selftest-session",
                           cwd=proj, transcript_path=os.path.join(tmp, "t.jsonl"))
            script = cmd.replace("${CLAUDE_PLUGIN_ROOT}", plugin_root).strip('"')
            name = f"hook {event}:{os.path.basename(script)}"
            try:
                p = subprocess.run(["bash", script], input=json.dumps(payload).encode(), capture_output=True,
                                   env=env, cwd=proj, timeout=30)
                n = _json_objects(p.stdout.decode("utf-8", "replace"))
                ok = p.returncode == 0 and 0 <= n <= 1
                why = "" if ok else f"exit {p.returncode}, {n} JSON object(s) on stdout"
            except subprocess.TimeoutExpired:
                ok, why = False, "timeout 30s"
            results.append({"control": name, "ok": ok, "why": why})
        results.append(_canary_failure(plugin_root, env, proj, tmp))
        results.append(_canary_gate(plugin_root, env, proj))
        results.append(_canary_claims(plugin_root, env, proj, tmp))
        results.append(_canary_probe(plugin_root, env, proj))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return results


def _canary_failure(root, env, proj, tmp):
    payload = dict(EVENT_PAYLOAD["PostToolUseFailure"], hook_event_name="PostToolUseFailure",
                   session_id="selftest-session", cwd=proj)
    subprocess.run(["bash", os.path.join(root, "scripts", "record-failure.sh")], input=json.dumps(payload).encode(),
                   capture_output=True, env=env, cwd=proj, timeout=30)
    rec = None
    for d, _, fs in os.walk(os.path.join(proj, ".claudehut")):
        for f in fs:
            if f.endswith("failures.jsonl"):
                with open(os.path.join(d, f)) as fh:
                    lines = [l for l in fh if l.strip()]
                if lines:
                    rec = json.loads(lines[-1])
    ok = bool(rec) and str(rec.get("exit") or rec.get("code") or "") == "7" and "selftest-stderr" in json.dumps(rec)
    return {"control": "canary record-failure keeps exit code + stderr", "ok": ok,
            "why": "" if ok else f"record = {json.dumps(rec)[:160] if rec else 'none written'}"}


def _canary_gate(root, env, proj):
    e = dict(env, CLAUDEHUT_GATE_MODE="block")
    cs = os.path.join(root, "bin", "claudehut-state")
    subprocess.run([cs, "--session", "selftest-gate", "start", "--route", "light", "--slug", "canary"],
                   capture_output=True, env=e, cwd=proj, timeout=30)
    p = subprocess.run([cs, "--session", "selftest-gate", "end", "--status", "done"], capture_output=True, env=e,
                       cwd=proj, timeout=30)
    ok = p.returncode == 1 and b"review-not-done" in p.stderr
    return {"control": "canary gate end refuses done without review (block)", "ok": ok,
            "why": "" if ok else f"exit {p.returncode}: {p.stderr.decode()[-160:]}"}


def _canary_claims(root, env, proj, tmp):
    md = os.path.join(tmp, "canary.md")
    with open(md, "w") as f:
        f.write("| a | ✓ | src/DoesNotExist.java:3 |\n")
    p = subprocess.run([os.path.join(root, "bin", "claudehut-verify"), "claims", md, "--json"], capture_output=True,
                       env=env, cwd=proj, timeout=30)
    try:
        probs = json.loads(p.stdout.decode()).get("problems", [])
    except ValueError:
        probs = []
    ok = p.returncode == 1 and any(x.get("kind") == "missing" for x in probs)
    return {"control": "canary verify claims reports a missing file", "ok": ok, "why": "" if ok else f"exit {p.returncode}"}


def _canary_probe(root, env, proj):
    p = subprocess.run([os.path.join(root, "bin", "claudehut-kernel"), "probe", "--project", proj],
                       capture_output=True, env=dict(env, CLAUDEHUT_PROBE_HOOKS="0"), cwd=proj, timeout=30)
    try:
        mode = json.loads(p.stdout.decode()).get("auth_mode")
    except ValueError:
        mode = None
    ok = mode in ("plan", "api", "bedrock", "vertex", "foundry")
    return {"control": "canary host probe answers", "ok": ok, "why": "" if ok else f"exit {p.returncode}"}
