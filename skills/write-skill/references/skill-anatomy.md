# Skill Anatomy — 3-Bucket Layout

## Required structure

```
skills/<skill-name>/
├── SKILL.md          ← required
├── references/       ← optional, load on demand
├── scripts/          ← optional, executable
└── assets/           ← optional, for output
```

## Bucket roles

### SKILL.md (always loaded when skill triggers)

- Frontmatter + workflow body.
- ≤ 500 lines hard, target ≤ 300.
- Quick-start + sub-procedure list + pointers to references.

### references/ (loaded by Claude as needed)

Markdown documentation for:
- Domain-specific knowledge.
- Worked examples.
- Anti-pattern lists.
- Variant-specific details (e.g., `mvc.md` vs `webflux.md`).

Rules:
- One level deep — no nested subdirs.
- TOC at top if > 100 lines.
- ≤ 500 lines per file.

### scripts/ (executable, run via Bash)

Bash/Python/Node scripts for:
- Deterministic operations (parsing, validation, scanning).
- Tasks repeated verbatim across invocations.
- Heavy operations Claude shouldn't reason through.

Rules:
- Self-contained or source plugin `lib/`.
- Print structured output (JSON preferred).
- Exit 0 on success, 1 on user-visible error, 2 on internal error.

### assets/ (NOT loaded into context)

Files used in OUTPUT (templates, boilerplate, snippets):
- `templates/*.tmpl` — text templates for files Claude generates.
- `boilerplate/` — directory templates (multi-file).
- Images / fonts / sample documents.

Rules:
- Never reference assets to "read for context" — only for "copy into output".
- Templates use `<PLACEHOLDER>` form for substitution.
