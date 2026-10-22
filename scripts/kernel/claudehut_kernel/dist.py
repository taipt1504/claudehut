"""Split distribution builder (K10, docs/v0.20 07 §2-§3, M2b).

The source stays ONE plugin (every suite runs against it, and it remains installable as the rollback path, 07 §6).
`build()` assembles two directory marketplaces from the pack manifests:

  <out>/claudehut[-canary]/              public marketplace
    plugins/claudehut/                   kernel + workflow-standard + review + lang-java-spring + lang-python-shell:
                                         every tracked file those packs own, plus the plugin's root metadata
  <out>/claudehut-internal[-canary]/     internal marketplace (never listed publicly, Q9)
    plugins/claudehut-org-summer/        org-summer's files, its own SessionStart hooks, and two kernel files vendored
                                         at the same path: the installer's import (scripts/index/extract.py) and the
                                         pack-registry hook (scripts/register-packs.sh)
    plugins/claudehut-backend-jvm/       bundle: only `dependencies` (claudehut from the public marketplace +
                                         org-summer), the documented bundle pattern

Versions and dependencies (M2b, verified in a spike, 10-implementation-log): `stable` stamps the plugin version
(users are pinned to it until the next bump); `canary` omits it, so a git-hosted canary marketplace versions every
commit by its SHA. Dependencies are bare names: a version RANGE resolves against `<plugin>--v<version>` git tags,
and a git-hosted relative-path plugin with no matching tag installs but stays disabled. Ranges come back with a
tagging step. `stable` refuses a dirty tree; every build writes dist-meta.json (source sha, dirty flag, channel).

Why only org-summer is split out (M2b decision gate, 10-implementation-log): the other packs reference each other's
files dozens of times and a plugin cannot read outside its own root, while hooks do not get other plugins' bin/ on
PATH (verified). org-summer has the distribution reason (internal content) and a two-point coupling. The rest stays
one plugin with logical packs until those references are cut.
"""
import json
import os
import shutil
import subprocess

from . import packs

PUBLIC_PACKS = ("claudehut-kernel", "workflow-standard", "review", "deliberation", "lang-java-spring", "lang-python-shell")
ROOT_META = (".claude-plugin/plugin.json", "README.md", "LICENSE", "CHANGELOG.md")
VENDORED = {"claudehut-org-summer": ["scripts/index/extract.py", "scripts/register-packs.sh"]}


def _tracked(root):
    out = subprocess.run(["git", "-C", root, "ls-files", "-z"], capture_output=True)
    if out.returncode != 0:
        raise RuntimeError("dist needs a git checkout of the plugin (tracked files only are shipped)")
    return [p for p in out.stdout.decode("utf-8", "replace").split("\0") if p]


def _copy(root, rel, dest_root):
    src = os.path.join(root, rel)
    dst = os.path.join(dest_root, rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(src, dst)


def _write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(obj, f, indent=2, ensure_ascii=False)
        f.write("\n")


def build(out, channel="stable", root=None):
    root = root or packs.plugin_root()
    manifests, errors = packs.load(root)
    if errors:
        raise RuntimeError(f"pack manifests: {errors}")
    base = json.load(open(os.path.join(root, ".claude-plugin", "plugin.json"), encoding="utf-8"))
    version = base["version"]
    sfx = "" if channel == "stable" else f"-{channel}"
    pub_mk, int_mk = f"claudehut{sfx}", f"claudehut-internal{sfx}"
    common = {k: base[k] for k in ("author", "homepage", "repository", "license") if k in base}
    tracked = _tracked(root)
    sha = subprocess.run(["git", "-C", root, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    dirty = bool(subprocess.run(["git", "-C", root, "status", "--porcelain", "--untracked-files=no"],
                                capture_output=True, text=True).stdout.strip())
    if channel == "stable" and dirty:
        raise RuntimeError("--channel stable needs a clean tree (commit first): a stable build must be reproducible "
                           "from its source sha")
    stamp = (lambda d: dict(d, version=version)) if channel == "stable" else (lambda d: d)
    owner = {rel: (packs.owners_of(rel, manifests) or [None])[0] for rel in tracked}

    if os.path.isdir(out):
        shutil.rmtree(out)
    report = {"channel": channel, "version": version, "marketplaces": {}}

    # ── public: claudehut ────────────────────────────────────────────────────────────────────────────────────
    pub = os.path.join(out, pub_mk)
    pdir = os.path.join(pub, "plugins", "claudehut")
    files = [r for r in tracked if owner[r] in PUBLIC_PACKS]
    files += [f"packs/{p}/claudehut-pack.json" for p in PUBLIC_PACKS] + ["packs/claudehut-pack.schema.json"]
    files += [m for m in ROOT_META if m in tracked]
    for rel in sorted(set(files)):
        _copy(root, rel, pdir)
    pj = dict(base)
    if channel != "stable":
        pj.pop("version", None)
    pj["description"] = (base.get("description", "") + " Distribution: kernel + workflow + review + Java/Spring "
                         "+ Python/shell packs.").strip()
    _write_json(os.path.join(pdir, ".claude-plugin", "plugin.json"), pj)
    _write_json(os.path.join(pub, ".claude-plugin", "marketplace.json"), {
        "name": pub_mk, "owner": {"name": base.get("author", {}).get("name", "ClaudeHut Authors")},
        "description": f"ClaudeHut kernel and packs ({channel} channel).",
        "plugins": [stamp({"name": "claudehut", "source": "./plugins/claudehut", "description": pj["description"],
                           "category": "development"})]})
    report["marketplaces"][pub_mk] = {"claudehut": len(set(files))}

    # ── internal: org-summer + bundle ────────────────────────────────────────────────────────────────────────
    itl = os.path.join(out, int_mk)
    sdir = os.path.join(itl, "plugins", "claudehut-org-summer")
    sfiles = [r for r in tracked if owner[r] == "org-summer"] + ["packs/org-summer/claudehut-pack.json", "LICENSE"]
    sfiles += VENDORED["claudehut-org-summer"]
    for rel in sorted(set(sfiles)):
        _copy(root, rel, sdir)
    _write_json(os.path.join(sdir, "hooks", "hooks.json"), {"hooks": {"SessionStart": [{
        "matcher": "startup",
        "hooks": [{"type": "command", "async": True,
                   "command": "\"${CLAUDE_PLUGIN_ROOT}/skills/summer-kb-setup/scripts/kb-maintain.sh\""}]}, {
        "matcher": "startup|resume",   # the pack registry (07 §1.1): how the kernel plugin learns this pack's root
        "hooks": [{"type": "command", "timeout": 5,
                   "command": "\"${CLAUDE_PLUGIN_ROOT}/scripts/register-packs.sh\""}]}]}})
    with open(os.path.join(sdir, "README.md"), "w", encoding="utf-8") as f:
        f.write("# claudehut-org-summer\n\nClaudeHut pack `org-summer`: the Summer Framework KB for consumer services "
                "(skill `summer-kb-setup`, install and self-heal at session start). Requires the `claudehut` plugin.\n")
    _write_json(os.path.join(sdir, ".claude-plugin", "plugin.json"), stamp(dict(common, **{
        "name": "claudehut-org-summer",
        "description": "ClaudeHut pack org-summer: Summer Framework KB for consumer services.",
        "dependencies": [{"name": "claudehut", "marketplace": pub_mk}]})))
    bdir = os.path.join(itl, "plugins", "claudehut-backend-jvm")
    with open(os.path.join(os.makedirs(bdir, exist_ok=True) or bdir, "README.md"), "w", encoding="utf-8") as f:
        f.write("# claudehut-backend-jvm\n\nBundle: installs `claudehut` and `claudehut-org-summer`.\n")
    shutil.copy2(os.path.join(root, "LICENSE"), os.path.join(bdir, "LICENSE"))
    _write_json(os.path.join(bdir, ".claude-plugin", "plugin.json"), stamp(dict(common, **{
        "name": "claudehut-backend-jvm",
        "description": "Bundle for JVM backend services: ClaudeHut + the org-summer pack.",
        "dependencies": [{"name": "claudehut", "marketplace": pub_mk}, "claudehut-org-summer"]})))
    _write_json(os.path.join(itl, ".claude-plugin", "marketplace.json"), {
        "name": int_mk, "owner": {"name": base.get("author", {}).get("name", "ClaudeHut Authors")},
        "description": f"ClaudeHut internal packs ({channel} channel).",
        "allowCrossMarketplaceDependenciesOn": [pub_mk],
        "plugins": [
            stamp({"name": "claudehut-org-summer", "source": "./plugins/claudehut-org-summer",
                   "description": "ClaudeHut pack org-summer.", "category": "development"}),
            stamp({"name": "claudehut-backend-jvm", "source": "./plugins/claudehut-backend-jvm",
                   "description": "Bundle: ClaudeHut + org-summer.", "category": "development"})]})
    report["marketplaces"][int_mk] = {"claudehut-org-summer": len(set(sfiles)) + 2, "claudehut-backend-jvm": 0}
    report.update(source_sha=sha, source_dirty=dirty)
    _write_json(os.path.join(out, "dist-meta.json"), report)
    return report
