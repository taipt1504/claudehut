# TDD Anti-Patterns — Catalog and Recovery

| Anti-pattern | What it looks like | Why bad | Recovery |
|--------------|-------------------|---------|----------|
| Code-before-test | Write impl, then write test that passes | Test certifies what was written, not what was needed | DELETE both. Restart with test first. |
| Test-after-implementation | Same as above, disguised — "I'll add the test now" | Identical issue | DELETE impl, write test, see it fail, then re-impl |
| Reference code while writing test | Have impl in another window for "reference" | Couples test to impl shape | Close impl. Write test from contract / spec. |
| Passing-on-first-RED | Test passes immediately | Tests existing behavior, not new | DELETE the test. Reframe to assert NEW behavior. |
| Skipping fail-verification | Run test, see green, move on | Don't know if test catches regression | Force the impl path to fail (mutate it), see if test catches. Then revert mutation. |
| Manual-test rationalization | "I tested it in Postman, no automated test needed" | No regression guard | Write the automated test BEFORE moving on. |
| "Just this once" | "TDD is overkill here, just push" | Compounds tech debt | No exceptions. Even small changes get tests. |
| Spirit-vs-ritual | "I'm following the spirit, not literally writing test first" | Self-deception; you don't know the spirit if you skip the ritual | Follow the ritual until it's habit. |
| Batched green | One impl makes multiple tests pass in one go | Too big a step — bug location ambiguous | Split into smaller cycles. |
| Big-bang refactor | Refactor 5 things, test once | Hard to isolate which change broke what | One refactor step, one verify. |
| Behavior-change in REFACTOR | "I cleaned up X, oh and also changed Y" | REFACTOR no longer means "no behavior change" | Revert. Behavior changes get their own RED-GREEN cycle. |
| Test logic in production | `if (isTest) { ... }` branches | Tests aren't really testing prod code | Refactor to inject dependencies; never branch on env. |

## Recovery template

If you catch yourself in an anti-pattern mid-cycle:

1. STOP.
2. `git stash` your current uncommitted work (safety).
3. Reset working tree to last green commit (`git reset --hard HEAD`).
4. Identify which anti-pattern.
5. Restart cycle from RED.
6. Stash can be discarded after — the test will tell you what to write.

## Smell detection

| Smell | Likely anti-pattern |
|-------|---------------------|
| Test file modified AFTER source file in same commit | Test-after |
| Test asserts trivial truth (`assertThat(true).isTrue()`) | Passing-on-first-RED |
| Test calls private method via reflection | Implementation-coupled |
| Test mocks the class under test | Wrong unit boundary |
| Test passes when impl returns null | Missing meaningful assertion |
| Two tests in same commit, both green from scratch | Code-before-test for both |
