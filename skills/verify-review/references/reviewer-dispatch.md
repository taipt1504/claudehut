# Reviewer Dispatch Pattern

## Parallel dispatch

In a SINGLE message, invoke multiple reviewer subagents via the Task tool. They run concurrently in isolated contexts and return summaries.

Example (pseudocode):

```
Task: claudehut-reviewer-security, args: {task_id: <id>}
Task: claudehut-reviewer-perf, args: {task_id: <id>}
Task: claudehut-reviewer-db, args: {task_id: <id>}
Task: claudehut-reviewer-reactive, args: {task_id: <id>}    # only if web_stack=webflux
Task: claudehut-reviewer-style, args: {task_id: <id>}
Task: claudehut-reviewer-mapping, args: {task_id: <id>}     # only if mapper=mapstruct or Jackson DTO involved
```

## Conditional inclusion

Read `claudehut-state stack web_stack` and `claudehut-state stack mapper`:

| Stack signal | Include reviewer |
|--------------|------------------|
| `web_stack=webflux` | reviewer-reactive |
| `web_stack=mvc` | skip reviewer-reactive |
| `mapper=mapstruct` OR `serialization=jackson` | reviewer-mapping |
| migration touched in diff | reviewer-db with extra focus |

## Output contract per reviewer

Each reviewer writes to `state/tasks/<id>/findings.json#reviewers.<reviewer-name>`:

```json
{
  "completed_at": "<ts>",
  "model": "<model-id>",
  "findings": [
    {
      "severity": "critical|high|medium|low",
      "category": "security|perf|db|reactive|style|mapping",
      "file": "src/main/java/com/x/Foo.java",
      "line": 42,
      "title": "...",
      "detail": "...",
      "suggestion": "..."
    }
  ]
}
```

## Aggregation (after all reviewers complete)

`scripts/aggregate-findings.sh` reads each reviewer's section, computes:

```json
{
  "totals": {
    "critical": 0,
    "high": 1,
    "medium": 4,
    "low": 7
  },
  "by_reviewer": { ... },
  "decision": "pass|fail"
}
```

## Anti-patterns

- **Serial dispatch**: invoking reviewers one at a time wastes wall-clock. Always batch in one message.
- **Reviewers writing code**: read-only. If they modify files → bug.
- **Ignoring low/medium**: they don't block this loop, but `claudehut:learn` records them for next time.
