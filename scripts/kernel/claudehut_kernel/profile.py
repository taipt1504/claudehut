"""K5 autonomy profile (docs/v0.20 04 §5.2, ADR K-08; M5e): the user's own ladder L0-L3 mapped to host permission
settings. The harness issues no grants: it only PRINTS the settings block for a level, and writes it into a settings
file only when the user runs it with --write <file> (HIL-3). Merges never cross L3: a merge to the default branch
stays with a person (auto-mode blocks it too).
"""
import json
import os

BUILD = ["Bash(./gradlew *)", "Bash(gradle *)", "Bash(./mvnw *)", "Bash(mvn *)", "Bash(python3 -m pytest*)"]
GIT_LOCAL = ["Bash(git add *)", "Bash(git commit *)", "Bash(git checkout -b *)", "Bash(git switch -c *)"]
ALWAYS_DENY = ["Bash(gh pr merge*)", "Bash(git push --force*)", "Bash(git push -f*)"]

LEVELS = {
    "L0": {"desc": "read-only: read and search", "mode": "plan", "allow": [],
           "deny": ["Write", "Edit", "NotebookEdit", "Bash(git push*)"]},
    "L1": {"desc": "local edit: change files in the repo", "mode": "acceptEdits", "allow": [],
           "deny": ["Bash(git push*)", "Bash(git commit*)"]},
    "L2": {"desc": "build and local git: build, test, commit locally", "mode": "acceptEdits",
           "allow": BUILD + GIT_LOCAL, "deny": ["Bash(git push*)"]},
    "L3": {"desc": "remote: push a branch and open a PR (merge stays with a person)", "mode": "acceptEdits",
           "allow": BUILD + GIT_LOCAL + ["Bash(git push origin *)", "Bash(gh pr create*)"], "deny": []},
}


def settings_for(level):
    lv = LEVELS[level]
    return {"permissions": {"defaultMode": lv["mode"], "allow": list(lv["allow"]),
                            "deny": list(lv["deny"]) + ALWAYS_DENY}}


def merge_into(path, level):
    """Merge the level's permissions into a settings JSON file: defaultMode set, allow/deny unioned (the user's own
    entries are kept, and an entry the level denies is removed from allow). → the new settings."""
    cur = {}
    if os.path.isfile(path):
        with open(path, encoding="utf-8") as f:
            cur = json.load(f)
    want = settings_for(level)["permissions"]
    perm = dict(cur.get("permissions") or {})
    perm["defaultMode"] = want["defaultMode"]
    deny = list(dict.fromkeys((perm.get("deny") or []) + want["deny"]))
    allow = [a for a in dict.fromkeys((perm.get("allow") or []) + want["allow"]) if a not in deny]
    perm["allow"], perm["deny"] = allow, deny
    cur["permissions"] = perm
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(cur, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)
    return cur
