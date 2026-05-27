# RED → GREEN → REFACTOR

## RED — Write a failing test

1. Open the test file. Add ONE test method.
2. Run the test command from the plan.
3. **Verify it fails.** Read the failure output. Confirm it failed for the right reason (e.g., `NoSuchMethodError`, `AssertionError: expected X but was Y`).
4. If it passes immediately → DELETE the test. You're testing existing behavior, not new behavior.
5. If it fails for the wrong reason (e.g., NullPointer on test setup) → fix the test, NOT the production code.

## GREEN — Make it pass with minimum code

1. Write the simplest implementation that satisfies the test.
2. Resist anticipating future tasks. No "while we're here" features.
3. Run the verify command.
4. **All tests in the verify command must pass.** Not just the new one.
5. Output must be clean — no new warnings/errors from neighbour tests.

## REFACTOR — Improve without changing behavior

1. Optional. Skip if the green code is already clean.
2. Allowed: rename, extract small method, deduplicate, remove dead branches.
3. Forbidden: add features, change signatures, change return types.
4. Re-run verify after each refactor step.

## Anti-patterns (will trigger restart)

| Anti-pattern | Why bad | Recovery |
|--------------|---------|----------|
| Writing production code before failing test | Test-after disguise | Delete code; start RED fresh |
| Test passes immediately on first RED | Testing existing behavior | Delete test; ensure test asserts new behavior |
| Using "reference code" while writing test | Couples test to impl, defeats TDD | Delete reference; write test from contract |
| Manual test "just this once" | Untested code | Add automated test before merging |
| Skipping fail-verification step | Don't know if test detects regression | Restart from RED |
| Batching multiple tasks in one commit | Loses bisection ability | Squash to per-task commits |
| Editing production code in REFACTOR to make a future task pass | Scope creep | Revert; defer to that task |

## Behavioral signal — clean RED looks like

```
Tests run: 12, Failures: 1, Errors: 0, Skipped: 0
- com.x.FooServiceTest.shouldRejectDuplicate:
    Expected: thrown DuplicateException
    Actual:   no exception thrown
```

vs **dirty RED**:

```
Tests run: 12, Failures: 0, Errors: 1, Skipped: 0
- com.x.FooServiceTest.shouldRejectDuplicate:
    NullPointerException at FooServiceTest.setup line 23
```

Dirty RED means test setup is broken, not that you've defined "new behavior to implement". Fix the test setup.
