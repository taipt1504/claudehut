# USAGE — how agents must use the Summer KB

This KB documents the **Summer Framework** (`io.f8a.summer`), the shared library that ewallet services
(wallet-ms, party-ms, …) consume. It is the authoritative source for how to wire and use Summer from a
consumer service. Read this before touching anything Summer-related.

## When to consult (mandatory triggers)
Consult this KB — do **not** answer from memory — whenever a task involves any of:
- Adding/removing a `io.f8a.summer:summer-*` dependency, or a `f8a.*` / `summer.*` config property.
- Turning a Summer feature on/off, or debugging why one is (or isn't) active — auto-config gates.
- Serializing/deserializing a `Ufid`/`Txid` (annotations `@JE`/`@SE`/`@TX`/`@Compact`/`@UInt128`/`@UfidPrefix`).
- Producing/consuming a Summer Kafka contract (`va.events`, `wallet.events`, `wallet.commands`, `payment.intent.command.v1`).
- Transactional outbox, audit trail, R2DBC converters, resource-server security, Keycloak roles, rate limiting, or blackbox tests.
- Any error, envelope, or exception type from Summer (`ApiResponse`, `ViewableException`, `CommonExceptions`).

If unsure whether Summer is involved: check `INDEX.md` §1 (module map) first — one read tells you.

## How to navigate (INDEX → module → graph node → source)
1. Open **[INDEX.md](INDEX.md)**.
   - Know the concern but not the module → **§3 topic map** ("I need X → doc + node").
   - Know it's a config key/gate → **§2 property cheat-sheet**.
   - Know the module → **§1 module map** (+ its Consumer-facing / Auto-config / Depends-on).
2. Open the module doc. It always has the same 7 sections — jump to the slot you need:
   `TL;DR · Activate · Config keys · Public API · Usage · Gotchas · Graph refs`.
3. Need the code → take the **graph node id** from the doc. A `file:` node id **is** the source path.
   Open it, or query `.understand-anything/knowledge-graph.json` (e.g. `understand-explain` on that node).

## Grounding rule (hard)
- Any decision about Summer wiring, config keys, gates, annotations, or on-wire contracts **MUST** cite a
  KB entry (module doc section + graph node / source path). Do not invent property names, gate defaults,
  bean names, or artifact coordinates.
- If the KB does not answer it, go to the graph node / source it points to and read — then, if it's a
  durable fact, add it to the module doc (same canonical template). Do not leave a guess in code.
- If a needed fact is unverifiable from source, write `[unverified]` — never a plausible guess.
- Doc format contract: every module doc = banner + the 7 fixed sections. Keep new content in the right slot.

## Staleness check (before trusting the KB)
The KB is built from the knowledge graph at a specific commit. Verify it still matches HEAD:
```bash
diff <(python3 -c "import json;print(json.load(open('.understand-anything/meta.json'))['gitCommitHash'])") \
     <(git rev-parse HEAD)
```
- Match → KB current; trust it.
- Differ → a Summer source change landed since the graph build. Treat affected module docs as possibly
  stale: re-read the source behind the graph node, and (if the graph is materially behind) refresh it with
  an incremental `/understand` before relying on cross-module claims. Do **not** silently trust a stale doc.

## Scope / boundaries
- This KB is **docs only** and stays local/untracked (commit-hygiene rule) — never `git add`/commit it.
- It documents Summer as a consumer sees it; it is not a place to record consumer-service-specific design.
