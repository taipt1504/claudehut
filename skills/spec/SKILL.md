---
name: spec
description: Phase 2 of ClaudeHut workflow — convert an approved design document into a binary behavioral contract (Given/When/Then, API shape, edge cases, NFRs). Use immediately after Brainstorm phase approval. Produces `.claudehut/specs/<id>-contract.md`. Triggers when phase=spec.
---

## Dispatch contract (read this FIRST)

This phase runs as a **subagent**, not inline in the main thread.
Main thread = orchestrator (context, memory, advisor, task tracking, user
dialog). Phase work = subagent (isolated context, per-phase model).

When you read this skill, you **MUST** invoke the Task tool:

```
Task(
  subagent_type = "claudehut-spec-writer",
  prompt        = <output of scripts/dispatch-prompt.sh "$ARGUMENTS">
)
```

Render the prompt by running `$CLAUDE_PLUGIN_ROOT/skills/spec/scripts/dispatch-prompt.sh "$ARGUMENTS"` and pass the stdout verbatim as the Task `prompt` argument. The script composes user intent + stack signals + conventions + recent learnings + prior-phase artifacts deterministically.

Do **not** execute the phase steps yourself in the main thread.
Await the subagent's return, review the artifact it wrote, surface a
concise status back to the user.

**Red flags that say "skip dispatch"** (counter each, do not give in):

| Rationalization | Reality |
|---|---|
| "This task is small — I'll inline it." | Inline = no isolated context + wrong model + breaks workflow gate. **Dispatch.** |
| "Subagent context is overkill." | This phase intentionally runs on `sonnet`. Main thread may be a different model — wrong tool. **Dispatch.** |
| "Design doc has enough detail; I'll skip contract." | Design ≠ contract. Spec adds Given/When/Then + NFRs. **Dispatch.** |
| "I'll write tests directly from design." | Tests need binary acceptance criteria. **Dispatch.** |

**Only exception**: user explicitly types `--inline` or "don't spawn a subagent". Then proceed inline and log the deviation in `.claudehut/findings/`.

---

# Spec — Phase 2

Convert design → contract that every test can binary-verify.

## Quick start

1. Read approved design at `.claudehut/specs/<id>-design.md`.
2. Render `assets/templates/contract-doc.md.tmpl` with task data.
3. Fill each section (acceptance, API shape, edge cases, errors, NFR, data contract, test surface).
4. Run `scripts/validate-contract.sh <path>` — exit 0 required.
5. Save to `.claudehut/specs/<id>-contract.md`.
6. Await user `approve`.

## Required sections (every contract MUST have)

- **Acceptance criteria** — Given/When/Then, each criterion binary
- **API shape** — exact Java signatures, REST paths + status codes, gRPC stubs, Kafka topic + schema
- **Edge cases** — null/empty/oversize/concurrent/timeout/downstream-fail/duplicate
- **Error responses** — RFC 7807 ProblemDetail for REST, DLT envelope for Kafka
- **NFR** — perf budget with numbers, security focus, observability, backpressure
- **Data contract** — DB schema delta, event schema, BC statement
- **Test surface** — unit / slice / integration / blackbox

Detailed format guide: `references/given-when-then.md`. NFR checklist: `references/nfr-checklist.md`. Worked examples: `references/examples.md`.

## Scripts

- `scripts/validate-contract.sh <contract-path>` — checks binary criteria, placeholder absence, signature consistency.

## Assets

- `assets/templates/contract-doc.md.tmpl` — contract skeleton.

## Hard rules

- Reject vague verbs ("handle", "validate") without specifics
- Every API signature MUST appear identically in every section that references it
- NFR MUST have numeric thresholds, not adjectives
- Every public method MUST have ≥ 1 negative-path acceptance criterion

## Exit criteria

- [ ] Contract file saved
- [ ] `scripts/validate-contract.sh` exits 0
- [ ] User typed `approve`
- [ ] Phase advanced to `plan`
