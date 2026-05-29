# Surgical Scope Rules

## What is "scope"

For each task in the plan, the union of:

- Files in `create:` block
- Files in `modify:` block
- Files in `test:` block

Plus auto-allowed:
- The plan file itself (to check off the task)
- `.claudehut/state/tasks/<id>/phase.json` (state mutation)
- `.claudehut/state/tasks/<id>/reuse-scan.json` (if running reuse-scan)

## Enforcement

The wired PreToolUse hook on Write/Edit (`hooks/pre-tool.sh`) checks the target file against the current task's plan scope inline. If file ∉ scope → permission denied. (Scaffold sessions set `CLAUDEHUT_SCAFFOLD=1` to bypass this, since they write whole-feature skeletons.)

To intentionally expand scope:

1. STOP. Update the plan first (`/claudehut:replan`).
2. Get user approval on the updated plan.
3. Then proceed.

## Common scope violations and recovery

| Violation | What happened | Recovery |
|-----------|---------------|----------|
| Touched neighbour class to make import work | Hidden coupling missed in plan | Update plan to include the neighbour; re-approve |
| Renamed a method, breaking unrelated callers | Refactor crept into Build | Revert; add as separate task |
| Edited `pom.xml`/`build.gradle` for missing dep | Plan didn't anticipate | Update plan to add dep task explicitly |
| Touched test of a different class | Test fix bleed | Revert; that test failure may indicate real regression |

## Allowed exceptions (still log)

- Format-only changes auto-applied by PostToolUse hook (Spotless) → allowed, no plan update.
- Comment removal from auto-generated boilerplate → allowed.

## Anti-cleanup principle

If you see unrelated dead code, formatting inconsistency, or pre-existing bugs in scope files → mention to user, don't fix. Build phase is for the task, not housekeeping.
