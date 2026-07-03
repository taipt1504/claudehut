---
name: summer-kb-setup
description: Install or refresh a service-scoped Summer Framework (io.f8a.summer) knowledge base in the current consumer service's docs/summer-kb/. Use when a service that depends on Summer needs its local KB, when onboarding a new ewallet service, when asked to "set up / install / refresh the Summer KB", or when Summer was upgraded and the local KB is stale. Detects which summer-* modules the service uses and installs only those docs plus an always-on pointer rule.
allowed-tools: Read Write Grep Glob Bash
---

# Summer KB Setup

Installs a **service-scoped** copy of the Summer Framework knowledge base into the consumer service, so its
agents ground Summer decisions in local docs. Invoked as `/claudehut:summer-kb-setup`.

> Normally you do NOT need this skill for first-time install: the ClaudeHut SessionStart hook detects a
> Summer consumer with no `docs/summer-kb/` and installs the KB automatically. Use this skill for manual
> installs, explicit refreshes, targeting another directory, or diagnosing a failed auto-install.

## What it does (one deterministic script)
1. Detects `io.f8a.summer:summer-*` deps in the service (`*.gradle`, `*.gradle.kts`, `*.toml`, excluding `build/`).
2. Maps them to module docs; **always includes `core`, `INDEX`, `USAGE`**.
3. Resolves the source of truth: sibling **`java-common-ms/docs/summer-kb/`** if present in the workspace
   (fresher), else the **bundled snapshot** in this skill (`references/summer-kb/`, stamped with the Summer commit).
4. Copies only the used module docs into `<service>/docs/summer-kb/`, generates a **scoped `INDEX.md`**,
   localizes `USAGE.md`.
5. Writes the always-on pointer `<service>/.claude/rules/summer-kb.md` (agents auto-load the KB).
6. Stamps `docs/summer-kb/.summer-kb-meta.json` (source, summerCommit, modules, detected artifacts).
Docs are local/untracked — the script does **not** `git add`/commit.

## How to run

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/skills/summer-kb-setup/scripts/install_summer_kb.py" [SERVICE_DIR]
```

- Preview with `--dry-run` (shows detected deps + modules, writes nothing).
- `SERVICE_DIR` defaults to the cwd.
- Report the script's summary: detected artifacts, included modules, source (sibling|bundled), files written.

## Edge cases
- **No `summer-*` deps** → exits 1, writes nothing (not a Summer consumer; do not force).
- **Unknown `summer-*` artifact** → listed as `unknownArtifacts`; flag it — the canonical KB in
  `java-common-ms/docs/summer-kb/` may need a new module doc.
- **No sibling java-common-ms** → bundled snapshot used; tell the user the KB reflects the bundle's
  `summerCommit` (see `references/summer-kb/.bundle-meta.json`) and may lag the live library.

## Refresh after a Summer upgrade
Re-run the installer — it overwrites the scoped docs from the current source. The SessionStart hook also
self-heals: when the plugin ships a newer bundle (`summerCommit` mismatch vs the service's
`.summer-kb-meta.json`), it re-runs this installer automatically at session start.

## Maintaining the bundled snapshot (plugin maintainer only)
When the canonical KB in `java-common-ms/docs/summer-kb/` changes:
```bash
cp <workspace>/java-common-ms/docs/summer-kb/*.md skills/summer-kb-setup/references/summer-kb/
# update references/summer-kb/.bundle-meta.json → summerCommit = java-common-ms .understand-anything/meta.json gitCommitHash
# bump plugin version (plugin.json + marketplace.json) so consumer sessions pick up the refresh
```
