# Skill Examples

## Table of contents

- [Example 1 — Phase skill](#example-1--phase-skill)
- [Example 2 — Tech-stack skill](#example-2--tech-stack-skill)
- [Example 3 — Quality skill](#example-3--quality-skill)
- [Example 4 — Meta skill](#example-4--meta-skill)

## Example 1 — Phase skill

Phase skills drive a workflow step. Mandatory, auto-trigger, produce artifacts.

```
skills/brainstorm/
├── SKILL.md                              ← Socratic protocol + 7-step
├── references/
│   ├── socratic-grilling.md              ← Q sequences
│   ├── reuse-detection-flow.md           ← algorithm
│   ├── design-doc-checklist.md           ← self-review
│   └── examples.md                       ← 3 worked
├── scripts/
│   ├── extract-nouns.sh                  ← parse topic
│   └── design-doc-selfreview.sh          ← validate
└── assets/templates/
    └── design-doc.md.tmpl                ← spec skeleton
```

Frontmatter pattern:

```yaml
---
name: brainstorm
description: "Phase 1 of ClaudeHut workflow — Socratic grilling..."
---
```

## Example 2 — Tech-stack skill

Tech-stack skills auto-load when matching file patterns are edited.

```
skills/spring-webflux/
├── SKILL.md                              ← core conventions
├── references/
│   ├── router-handler-pattern.md
│   ├── schedulers.md
│   ├── context-propagation.md
│   └── anti-patterns.md
└── assets/templates/
    ├── Handler.java.tmpl
    └── RouterConfig.java.tmpl
```

## Example 3 — Quality skill

Quality skills enforce specific practices (TDD, OWASP scan).

```
skills/tdd-cycle/
├── SKILL.md                              ← RED-GREEN-REFACTOR
├── references/
│   ├── red-green-refactor.md             ← detailed
│   └── anti-patterns.md
└── scripts/
    └── watch-test-fail.sh                ← verify test FAILS
```

## Example 4 — Meta skill

Meta skills extend ClaudeHut itself.

```
skills/write-skill/
├── SKILL.md                              ← scaffold instructions
├── references/
│   ├── skill-anatomy.md
│   ├── frontmatter-contract.md
│   └── examples.md
├── scripts/
│   ├── init-skill.sh                     ← scaffold
│   └── validate-skill.sh                 ← lint
└── assets/templates/
    └── skill-skeleton/
        └── SKILL.md.tmpl
```

## Anti-example — bad skill

```
skills/foo-helper/
├── SKILL.md
├── README.md                  ← FORBIDDEN
├── INSTALL.md                 ← FORBIDDEN
├── reference1.md              ← should be inside references/
├── ref/                       ← wrong name, use references/
└── helper.sh                  ← should be inside scripts/
```
