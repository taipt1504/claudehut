---
name: brainstorm
description: Use at the very start of any non-trivial Java/Spring change — before specifying, planning, or writing any code, and before adding any new class, service, utility, config, filter, or endpoint. Grounds the work in the existing codebase, proves whether something reusable already exists, and produces two or more codebase-adapted options plus the enforcement set. This is the Brainstorm phase entry point.
---

# Brainstorm (phase 1 of 6)

The Brainstorm phase turns a raw request into a **grounded, reuse-checked, scored set of options** and the
**enforcement set** that the rest of the workflow audits against. It folds three steps — explore, reuse-scan,
option generation — into one phase. Run it **inline on the main thread**: it dispatches three subagents in
sequence, and a forked subagent cannot itself spawn subagents.

## Iron Law

```
NO NEW CLASS, SERVICE, UTILITY, CONFIG, OR ENDPOINT BEFORE A REUSE SCAN
```

Wrote new code without a reuse-scan artifact? Delete it and scan first. **Delete means delete** — don't keep
it "as a reference." The `PreToolUse` write gate enforces this: until `reuse_scan=true`, every production
write is denied.

## Flow

```mermaid
flowchart TB
    start([Brainstorm phase]) --> ph["claudehut-state set-phase brainstorm"]
    ph --> explore["Step 1 — dispatch claudehut-explorer (Agent tool)<br/>read PROJECT.md / architecture.md / reuse-index.json<br/>return entry points, key types, Reuse candidates"]
    explore --> reuse["Step 2 — dispatch claudehut-reuse-scanner (Agent tool)<br/>write reuse-scan-&lt;task&gt;.md (FOUND/none + DECISION)<br/>set-reuse-scan --artifact …"]
    reuse --> opts["Step 3 — dispatch claudehut-brainstormer (Agent tool)<br/>≥2 scored options + recommendation<br/>build enforcement set (1% rule) → set-enforcement"]
    opts --> gate{"reuse_scan=true<br/>AND option chosen<br/>AND enforcement_set recorded?"}
    gate -- no --> opts
    gate -- yes --> done([REQUIRED NEXT: claudehut:write-spec])
```

## Step 1 — Explore (dispatch `claudehut-explorer`)

Dispatch the explorer with the Agent tool. It loads the pre-built index (`.claude/claudehut/PROJECT.md`,
`architecture.md`, `reuse-index.json`), maps the packages/classes the task touches (cite `file:line`), and
returns entry points, key existing types, and a **"Reuse candidates"** list. It never edits and never
proposes fixes. If `understand-anything` is enabled (flag set by `claudehut:claudehut-workflow` at
SessionStart), the explorer uses its query/search skills for richer navigation; otherwise `Grep`/`Glob`.

## Step 2 — Reuse-scan (dispatch `claudehut-reuse-scanner`)

Dispatch the reuse-scanner. It queries `reuse-index.json` by tag, greps for similar signatures/annotations,
reads learnings tagged `reuse`, then writes the reuse-scan to the **absolute canonical path**
`${CLAUDE_PROJECT_DIR}/.claude/claudehut/reuse-scan-<task>.md` (NOT a bare `.claudehut/` path — the state
writer and the write gate both require it under `.claude/claudehut/`), containing: searched tags/terms,
**FOUND** (component + `file:line`) or **none**, **DECISION** (adopt / extend / new), and a justification for
any new code. It then records the artifact:

```
claudehut-state --session ${CLAUDE_SESSION_ID} set-reuse-scan --artifact .claude/claudehut/reuse-scan-<task>.md
```

| Rationalization | Reality |
|--------|---------|
| "Nothing like this exists here" | Then the 60-second scan confirms it and costs nothing. Run it. |
| "It's faster to just write it" | A duplicate you later reconcile is slower. Scan. |
| "I already explored, I know the code" | Exploration ≠ a reuse decision. Produce the artifact. |
| "It's a tiny helper" | Tiny duplicates rot fastest. Scan. |

## Step 3 — Options + enforcement set (dispatch `claudehut-brainstormer`)

Dispatch the brainstormer. It produces **≥2 genuinely distinct, codebase-adapted approaches** scored on
three axes, presented as a table (approach · pros · cons · fit-with-project · footprint · perf) plus a
recommendation:

1. **Most best-practice** — idiomatic for this stack/version.
2. **Smallest change footprint** — adopting/extending the reuse-scan candidate is option 0.
3. **Highest output quality + performance.**

Then it builds the **enforcement set** by the 1% rule — *if there is even a 1% chance a skill or rule
applies, it MUST be included* — scanning the plugin skills and the project's `.claude/rules/` tree:

```
claudehut-state --session ${CLAUDE_SESSION_ID} set-enforcement --skills <a,b,c> --rules <framework/jpa.md,security/owasp-top10.md,…>
```

The enforcement set is an **auditable checklist** Review will enforce — not a new mechanism. In interactive
use, confirm the chosen option with the user before leaving Brainstorm.

## Red flags — STOP

- About to write production code with no `reuse-scan-<task>.md` on disk
- Only one option ("the obvious way") — the law requires ≥2 distinct, codebase-adapted approaches
- Enforcement set left empty because "nothing really applies" — re-apply the 1% rule against `.claude/rules/`

**REQUIRED NEXT:** `claudehut:write-spec`.
