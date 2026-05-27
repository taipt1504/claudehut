---
name: systematic-debug
description: Structured debugging protocol — reproduce → isolate (bisect) → root cause → test → fix. Used on-demand when a bug appears outside Phase Loop (e.g., user reports a failing test, prod incident). Slash-invoke /claudehut:debug <symptom>. Does not auto-trigger; user-controlled.
disable-model-invocation: true
---

# Systematic Debug

Discipline for debugging instead of guessing.

## Quick start

```bash
/claudehut:debug "UserService.create throws NPE on duplicate email"
```

Follows 5-step protocol:

1. **Reproduce.** Write a failing test or capture exact commands that trigger the bug.
2. **Isolate.** Bisect by code (git bisect) or by inputs (binary search input space).
3. **Root cause.** Read the offending code path. State the bug in one sentence: "X happens because Y when Z."
4. **Test.** Write a test that asserts correct behavior. Run it — must FAIL with current code.
5. **Fix.** Minimal change. Test now passes. No "while we're here" cleanup.

Detailed protocols:
- `references/reproduce-protocol.md` — making a flaky bug reliable.
- `references/bisect-strategy.md` — narrowing scope quickly.
- `references/examples.md` — 3 worked debug sessions.

## Scripts

- `scripts/reproduce-helpers.sh` — quick fixtures for common reproduction patterns (DB state, request, event).

## When to use

- Bug reported outside the workflow (incoming user report, prod incident).
- Phase 5 finding that didn't have obvious fix in the diff.
- Persistent flaky test.

## When NOT to use

- Spec is wrong: not a bug, go back to Phase 2.
- Symptoms ambiguous: clarify with user before debugging.
- Verify pipeline failing across many tests: it's likely env, not a single bug.

## Hard rules

- ALWAYS reproduce before fixing. No "let me try this fix" without a failing case.
- ALWAYS write the test before the fix. TDD applies to bug fixes too.
- ROOT CAUSE in writing. If you can't write the bug in one sentence, you don't understand it.
- Fix is minimal. No incidental refactor.

## Exit criteria

- [ ] Failing test committed first
- [ ] Root cause written in commit message body
- [ ] Test passes after fix
- [ ] No unrelated changes in the diff
