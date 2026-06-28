# Spec template (copy per task → `.claude/claudehut/tasks/NNNN-<slug>/spec.md`)

<!-- Synthesis: GitHub spec-kit (user stories, GWT acceptance, [NEEDS CLARIFICATION]) · AWS Kiro (EARS
     functional requirements) · MADR 4.x (decision record) · Google design docs (goals/non-goals).
     ClaudeHut-specific: §12 enforcement manifest. -->

**Right-sizing rule — pick by `type`, don't emit "N/A" walls:**
- `feature` → ALL sections.
- `refactor` / `bugfix` → REDUCED subset: §1 Problem & Context, §9 Decision Record, §5 Acceptance Criteria,
  §10 Out of Scope, §12 Enforcement Manifest (omit the other headings entirely).

```markdown
# Spec: <task title>

> id: NNNN-<slug> · type: feature|refactor|bugfix · status: draft|approved · date: YYYY-MM-DD
> approval: <approved via AskUserQuestion | non-interactive run — proceeded with draft>
> brainstorm: tasks/NNNN-<slug>/brainstorm.md  <!-- the deliberation this decision came from (full tier) -->

## 1. Problem & Context
One paragraph: why this change, the current pain, the bounded scope. Cite codebase facts from Explore
(`file:line`), and the reuse decision (adopt/extend/new) from the reuse-scan.

## 2. Goals / Non-Goals
- Goals: outcome-oriented, measurable ("p99 < 200ms on /orders").
- Non-Goals: plausibly-related things deliberately excluded.

## 3. User Story                                    <!-- feature only -->
AS A <role> I WANT <capability> SO THAT <outcome>.

## 4. Functional Requirements (EARS)                <!-- feature only -->
Numbered FR-001…; use the EARS patterns; mark unknowns [NEEDS CLARIFICATION: …].
- FR-001 WHEN <trigger> THE SYSTEM SHALL <response>
- FR-002 IF <unwanted condition> THE SYSTEM SHALL <guard behavior>
- (WHILE <state> … / WHERE <feature enabled> … as needed)

## 5. Acceptance Criteria
One Given/When/Then block per FR (or per fixed behavior for a bugfix) — machine-checkable outcomes only
(HTTP status, DB state, emitted event, log entry, metric):
- AC-001 (FR-001): GIVEN <precondition> WHEN <action> THEN <observable outcome>

## 6. API Contract Changes                          <!-- feature only; "none" allowed -->
Method + path + request/response schema + error codes. Note backward-compat guarantee.

## 7. Data Model Changes                            <!-- feature only; "none" allowed -->
Tables/columns touched; Flyway/Liquibase migration id; whether a down-path exists.

## 8. NFRs                                          <!-- feature only; deltas only -->
- Performance: latency/throughput targets this change must hold.
- Security: authz boundary, input-validation rules, fields that must never log.

## 9. Decision Record (MADR-lite)
- Problem statement: one sentence — the core design question.
- Drivers: the constraints that matter (perf, consistency, team convention, footprint).
- Options: A / B / C — one-line trade-off each (these come from Brainstorm's scored options).
- **Outcome: <chosen option> — because <how it best satisfies the drivers>.**
- Confirmation: the test/review that will validate the decision.
- Consequences: (+) …, (−) ….
- **Budget: ≤80 words. One line per considered option.** Do NOT echo Brainstorm's scoring tables or
  /500 numbers here — **link them instead** (`> brainstorm:` in the header points at `brainstorm.md`, the
  full options table + premortem). The spec records the decision + why; the deliberation stays traceable
  one click away, not lost.

## 10. Out of Scope
Explicit neighbouring concerns excluded (UI, auth flow, other services…).

## 11. Open Questions
Numbered; each with an owner and a [NEEDS CLARIFICATION] marker if blocking.

## 12. Enforcement Manifest (ClaudeHut)
The skills + rules from Brainstorm's enforcement set that Review will audit this task against.
**>5 rules → use the two-column table; NEVER a prose list** (29 rules in one paragraph is unscannable —
the reviewer must be able to tick each row):
- skills: claudehut:implement, …

| Rule file | Category |
|-----------|----------|
| framework/jpa.md | orm |
| security/owasp-top10.md | security |
```
