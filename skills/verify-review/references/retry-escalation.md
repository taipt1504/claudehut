# Retry & Escalation Logic

## Retry counter

Tracked in `state/tasks/<id>/loop-counters.json`:

```json
{ "loop_retries": 0, "last_iteration_at": "<ts>" }
```

Increment after each FAIL.

## Refactor task injection

On FAIL:

1. Compose a synthetic refactor task and append to `.claudehut/plans/<id>-plan.md`:

```markdown
## Task <N+1>: Refactor — address findings from loop iteration <retry>

**Covers:** all Critical + High findings from findings.json

**Files:** <union of files mentioned in Critical/High findings>

**RED:** (existing test suite, no new test needed unless reviewer flagged missing coverage)

**GREEN:** Fix each Critical/High finding:
- finding-1: <title> → <suggestion>
- finding-2: ...

**Verify:**
\`\`\`bash
./gradlew check
\`\`\`

**Depends on:** previous task
**Risk:** <inherit from original tasks>
```

2. Phase remains `build`. Loop counter incremented.

## Escalation (retry == 3)

Stop the loop. Compose escalation report:

```markdown
## ClaudeHut Loop Escalation

Task: <id>
Retries: 3/3 (max reached)

### Persistent findings

<list of Critical/High that persisted across all retries>

### Recommendations

1. Re-plan: <suggestion if rooted in design>
2. Abandon: <criteria if not feasible>
3. Accept with caveat: <when accepting medium severity>

User input required to proceed.
```

Hand control back to user via orchestrator. Do NOT auto-retry beyond 3.

## When user re-plans

User responds with new plan or accepts findings → reset loop counter, phase back to `plan` (if re-plan) or `learn` (if explicit accept).

## Anti-patterns

- **Silent retry beyond 3**: never. Escalate visibly.
- **Cosmetic refactor instead of root cause**: each refactor task MUST cite the finding it addresses.
- **Reopening already-resolved findings**: track resolved findings in `state/tasks/<id>/resolved-findings.json`.
