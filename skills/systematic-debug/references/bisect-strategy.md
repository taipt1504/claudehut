# Bisect Strategy

## Bisect by code (git bisect)

When a recent change broke it.

```bash
git bisect start
git bisect bad HEAD                           # current is broken
git bisect good <known-good-sha>              # 2 weeks ago worked

# Loop:
# 1. Git checks out a midpoint commit
# 2. Run your reproduction test
# 3. Mark good or bad
git bisect good     # or git bisect bad
git bisect run ./run-repro.sh                 # automated mode
```

`run-repro.sh` exits 0 if good, non-zero if bad. Git automates the binary search.

## Bisect by input

When the bug depends on a specific input combination.

- Split input space in half. Try larger half.
- If bug present → eliminate other half.
- Repeat until minimal input found.

Example: API returns 500 on certain request bodies.

1. Try empty body → 400 (different error, not our bug).
2. Try minimal valid body → 200 (good).
3. Try body with field A only → 200.
4. Try body with field A + B → 500. (← culprit involves A+B combination)
5. Vary A while B fixed → narrow A's role.
6. Vary B while A fixed → narrow B's role.

## Bisect by feature flag

If a recent feature flag enabled it:

```bash
# Toggle off, test
LD_FLAG_X=false ./run-repro.sh
# If now good → flag-related. Inspect what changes with the flag.
```

## Bisect by config

Production differs from staging? Diff config files.

```bash
diff <(kubectl get cm prod-config -o yaml) <(kubectl get cm staging-config -o yaml)
```

Toggle config values one at a time on staging until staging fails.

## When bisect is hard

- Build broken at the midpoint commit → `git bisect skip`.
- Flaky reproduction → run repro N times, mark as bad only if rate > threshold.
- Bug requires data setup → automation script.

## Anti-patterns

- Bisecting without a reliable repro → false positives mislead.
- Manual bisect when automation possible → wastes time.
- Stopping at "first bad commit" without understanding → fix the surface change, miss the root.
