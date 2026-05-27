---
name: init
description: Scaffold the .claudehut/ directory in the current Java project (creates memory/, specs/, plans/, state/, rules/ subdirs and seeds template configs). Run via /claudehut:init when first enabling ClaudeHut on a project. One-time per project; refuses if directory already exists.
---

# Init — One-time Project Bootstrap

Scaffold `.claudehut/` in current project. Refuses if already initialized.

## Quick start

Run `scripts/init-project.sh`. Reads from `templates/` in plugin root, writes to `.claudehut/` in project.

## What gets created

```
<project>/.claudehut/
├── claudehut-config.json                  # from templates/claudehut-config.template.json
├── memory/
│   ├── stack-signals.json                 # from templates/stack-signals.template.json (then auto-detected)
│   ├── conventions.md                     # from templates/conventions.template.md
│   ├── index.md                           # from templates/index.template.md
│   ├── learnings.jsonl                    # empty
│   └── reusable-impl-map.json             # empty {}
├── specs/                                 # empty
├── plans/                                 # empty
├── state/
│   ├── tasks/                             # empty
│   └── lockfile.d/                        # empty
└── rules/                                 # empty (project-local rule overrides)
```

Also appends to `.gitignore` (if present):

```
.claudehut/state/lockfile.d/
.claudehut/state/active-task.json
.claudehut/state/tasks/*/loop-counters.json
.claudehut/state/tasks/*/reuse-scan.json
.claudehut/state/tasks/*/compact-snapshot.json
.claudehut/state/integrations.json
```

## Post-init checklist

1. Review `.claudehut/claudehut-config.json` (loop_max_retries, coverage thresholds).
2. Verify `.claudehut/memory/stack-signals.json` reflects your stack (will be auto-detected on next SessionStart if `unknown` fields).
3. Edit `.claudehut/memory/conventions.md` with project-specific naming/architecture rules.
4. Commit `.claudehut/` directory (gitignore patterns already added).
5. (Optional) Install reuse-detection plugins: Understand-Anything, Graphify.

## Hard rules

- Refuses to overwrite existing `.claudehut/`. Use `--force` flag at your own risk (not implemented in Sprint 1).
- Reads templates from `${CLAUDE_PLUGIN_ROOT}/templates/`.

## Exit criteria

- [ ] `.claudehut/` directory exists
- [ ] All template files copied
- [ ] `.gitignore` patches appended
