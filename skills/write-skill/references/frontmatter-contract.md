# Frontmatter Contract

## Required fields

```yaml
---
name: kebab-case-name
description: "<what skill does> Use when <triggers>. Triggers: <natural> + <code>."
---
```

### name

- Must match folder name exactly.
- Lowercase kebab-case: `verb-object` or `domain-name`.
- No numbers, no abbreviations.

### description

- Single string, ≤ 200 chars recommended (hard limit 500).
- Contains BOTH what + when-to-use triggers.
- This is the ONLY content Claude reads to decide if skill should auto-trigger.
- Do NOT put "When to use" sections in body — body only loads AFTER trigger.

## Optional fields

```yaml
allowed-tools: [Read, Grep, Glob, Bash, Skill]
disable-model-invocation: false
model: claude-haiku-4-5
```

### allowed-tools

Restrict tools the skill can use when invoked. Defaults to inheriting caller's tools.

### disable-model-invocation

If `true`, skill only invokable via explicit `/skill-name` slash. Claude won't auto-trigger from `description` match.

Use cases: destructive actions (`rollback`), confirmations (`finish`), state inspection (`discover`).

### model

Pin a specific model. Useful for cost optimization:
- `claude-haiku-4-5` for extraction/parsing/quick lookups.
- `claude-sonnet-4-6` for balanced reasoning.
- `claude-opus-4-7` for deep design/planning.

## ClaudeHut extensions (read by hooks, harness ignores)

```yaml
claudehut:
  phase: brainstorm
  mandatory: true
  triggers:
    natural: ["add feature", "implement"]
    code: ["UserPromptSubmit"]
  auto-enforce-when: "phase == 'none'"
  produces:
    - .claudehut/specs/<id>-design.md
  next-phase-skill: spec
```

These fields:
- Read by `scripts/hooks/prompt-router.sh`.
- Used for phase routing and auto-enforce decisions.
- Not standard Claude Code — won't break anything if removed.

## Anti-patterns

| Bad | Why bad |
|-----|---------|
| `name: My Skill` | Spaces, capital case |
| `description: A skill for things` | Vague — Claude can't decide when to use |
| `## When to use` section in body | Body only loads after trigger; this section invisible |
| `description: < 30 chars` | Too short for trigger decision |
| `name` ≠ folder name | Breaks slash command resolution |
| Multiple frontmatter blocks | Only first is parsed |
