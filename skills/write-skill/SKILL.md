---
name: write-skill
description: Scaffold a new ClaudeHut skill in the 3-bucket layout (SKILL.md + references/ + scripts/ + assets/): validates the frontmatter contract, applies naming conventions, generates a skeleton. Run via /claudehut:write-skill <name>.
---

# Write-Skill

Generate a new skill conforming to Anthropic skill-creator best practices.

## Quick start

```bash
/claudehut:write-skill <skill-name> <one-line-description>
```

The script `scripts/init-skill.sh` creates:

```
skills/<skill-name>/
├── SKILL.md          ← frontmatter + body skeleton
├── references/
│   └── .gitkeep
├── scripts/
│   └── .gitkeep
└── assets/
    └── templates/
        └── .gitkeep
```

## SKILL.md frontmatter contract

Required:
- `name` — kebab-case, matches folder name.
- `description` — what + when-to-use triggers, ≤ 200 chars.

Optional:
- `allowed-tools: [Read, Grep, ...]` — restrict tool set.
- `disable-model-invocation: true` — only invokable via slash command.
- `model: claude-haiku-4-5` — pin model.

References on frontmatter contract: `references/frontmatter-contract.md`. 3-bucket anatomy: `references/skill-anatomy.md`. Examples: `references/examples.md`.

## Scripts

- `scripts/init-skill.sh <name> <description>` — scaffold skill directory.
- `scripts/validate-skill.sh <skill-path>` — check frontmatter + structure compliance.

## Assets

- `assets/templates/skill-skeleton/` — full skeleton with placeholders ready to customize.

## Hard rules

- Skill folder name = `name` in frontmatter. Identical.
- ≤ 500 lines for SKILL.md body. Target ≤ 300.
- No README.md / INSTALL.md / CHANGELOG.md inside skill folder (Anthropic guideline).
- References ≤ 200 lines per file. TOC mandatory if > 100 lines.

## Exit criteria

- [ ] Skill folder exists at `skills/<name>/`
- [ ] SKILL.md has valid frontmatter
- [ ] `references/`, `scripts/`, `assets/templates/` exist (may be empty)
- [ ] `scripts/validate-skill.sh` exits 0
