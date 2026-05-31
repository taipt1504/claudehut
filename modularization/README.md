# ClaudeHut modularization (Phase 6.3)

> **Disposition (2026-05-31): RESOLVED — single-plugin distribution is the intent.**
> A 4-plugin split is *not* a user requirement, so this partition ships as the
> maintainability / release-readiness substrate (and the proof that the taxonomy
> partitions cleanly), not as a pending split. If separate distribution is ever
> wanted, the split is blocked on CC #9444 and is mechanical from `modules.json`.

## What ships here

`modules.json` — a **logical partition** assigning every skill (31) and rule (47)
to exactly one module: `core` (the workflow engine + cross-cutting domain skills),
`spring`, `messaging`, `quality`. `tests/static/module-coupling.sh` (run-all.sh L27)
proves the partition is complete, disjoint, and **clean**: no `spring↔messaging↔quality`
reference edge exists — packs depend only on `core` (and themselves).

That settles the original design objection ("the taxonomy doesn't partition —
jackson/lombok/mapstruct/testcontainers/wiremock are cross-cutting"). It does
partition, once the cross-cutting skills are assigned to `core`. The proof is data,
not assertion.

## Why this is a partition, not 4 plugins (BLOCKED-ON-PLATFORM, issue #9444)

A physical 4-plugin split is blocked by the Claude Code plugin model, not by taste:

- **CC discovers skills only at the flat plugin root** `skills/<name>/` — there is no
  nested per-module skill root inside one plugin.
- **CC plugins are completely independent units** with **no cross-plugin references
  and no dependency resolution** (CC docs; tracked as feature request
  [anthropics/claude-code#9444](https://github.com/anthropics/claude-code/issues/9444)).

ClaudeHut has **180 `claudehut:`-namespaced cross-references across 59 files**. Splitting
into 4 independently-installed plugins would force one of two worse outcomes:

1. **Duplicate the engine** (hooks/state/orchestrator) into every pack — 4 copies
   racing to register the same hooks (the workaround the CC docs explicitly name); or
2. **Rewrite all 180 refs** to per-pack namespaces (`claudehut-messaging:kafka-consumer`)
   — which loses the standalone-core guarantee, since CC will not enforce that the
   packs a core ref needs are actually installed.

Both make the product worse to satisfy a packaging goal. So the **partition is
delivered and proven today**; physical multi-plugin **distribution waits on
cross-plugin resolution the platform does not yet have** (#9444). This is the same
category as a resource gate — an external constraint named to a tracking issue — not
a deferral by choice.

## How a future split consumes this

When #9444 lands (plugin `dependencies` + a library/exported-resource type), the split
is mechanical and the proof above guarantees it is clean:

- `core` becomes a library plugin exporting the engine + cross-cutting skills/rules.
- `spring` / `messaging` / `quality` become plugins that `depends-on: [core]`, each
  carrying only the skills/rules `modules.json` assigns it.
- The L27 no-pack→pack invariant guarantees no pack needs another pack — only `core`.

Re-run `tests/static/module-coupling.sh` after any skill/rule add to keep the
partition honest (a new skill must be assigned, and must not introduce a pack→pack edge).
