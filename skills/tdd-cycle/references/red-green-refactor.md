# RED → GREEN → REFACTOR — Detailed

## RED

### What to do

1. Open the test file.
2. Add ONE test method. Name it for the behavior, not the impl.
3. Run the test command (e.g., `./gradlew test --tests 'com.x.FooTest.shouldRejectDuplicate'`).
4. **Read the failure output.** Confirm:
   - It failed (not passed, not errored on setup).
   - The failure type matches expectation (`AssertionFailedError`, `NoSuchMethodError`).
   - The failure message is meaningful.

### Acceptable failure types

- `AssertionFailedError` — assertion didn't match. The test logic works; impl missing or wrong.
- `NoSuchMethodError` / compile error — method doesn't exist yet. Expected.
- `NullPointerException` from impl — impl is partial; missing branch. Expected.

### NOT acceptable

- `NullPointerException` in TEST setup (line 23 of test) → test is broken; fix test.
- Test passes immediately → DELETE the test; ensure the test actually asserts new behavior.
- Error in `@BeforeEach` → test infrastructure broken; fix infrastructure.

### Watch test fail — the discipline

Run `scripts/watch-test-fail.sh <spec>`. It exits 0 ONLY if the test FAILED. If it returns non-zero, your test passed (delete and retry) or errored (fix setup).

## GREEN

### Rules

- Write the LEAST code to make THIS test pass.
- Don't anticipate the next test.
- Don't add fields, methods, configs unless needed.
- Don't change unrelated code.

### Run

- Run the target test.
- Run neighbour tests in the same class.
- Run the next-broader suite (e.g., `./gradlew :module:test`).
- All must pass. Clean output.

### Common temptation to resist

- "While I'm here, let me also add validation for X." → No. That's a separate test cycle.
- "Let me refactor this nearby method." → No. That's REFACTOR step, not GREEN.
- "Let me add a comment explaining this." → If non-obvious, OK. If WHAT not WHY, delete.

## REFACTOR

### When to refactor

- The green code is ugly (named poorly, duplicated, long method).
- A clearer structure is obvious to you.

### When NOT to refactor

- Code is already clean.
- You're guessing the cleaner structure.
- Other team conventions disagree.

### What's safe

- Rename variables/methods/classes (use IDE refactor).
- Extract method.
- Inline method/variable.
- Remove dead code.

### What's NOT safe

- Change return type.
- Change signature (callers break).
- Change error type thrown.
- Add or remove parameters.

If unsafe, that's a new test cycle, not REFACTOR.

### Verify after each refactor step

- Run target test.
- Run neighbours.
- If broken → undo. Don't try to fix forward.

## Commit boundary

ONE commit per RED-GREEN cycle. REFACTOR can be part of same commit OR separate (`refactor: ...`).

Typical commit:

```
feat(user): reject duplicate on create

Adds DuplicateUserException thrown when email already exists.
Covered by FooServiceTest.shouldRejectDuplicate.
```
