# DAG Dependency Construction

## Rules

1. Acyclic. If you find a cycle, you're modeling state, not dependencies — refactor.
2. Each `Depends on:` references task numbers, not titles.
3. Tasks with no dependencies can run in parallel (in theory; Builder agent serializes anyway).
4. Linear dependencies are fine and common.

## Common patterns

### Strict linear

```
T1 → T2 → T3 → T4
```

Used when each task strictly requires the previous (e.g., add field, then use field, then expose in API).

### Fan-out

```
       ┌─ T2a
T1 ────┤
       └─ T2b
```

Used when one foundation enables multiple parallel pieces (e.g., create base interface, then add 2 implementations).

### Fan-in

```
T1a ─┐
T1b ─┤── T2
T1c ─┘
```

Used when integration depends on multiple components being ready.

### Migration coupling

```
T1: create nullable column   ─► T2: backfill data ─► T3: NOT NULL constraint
                                       │
                                       └─► T2.5: update app code to read tolerantly
```

The "T2.5" branch is critical for rolling deployments.

## Anti-patterns

- **Hidden coupling**: T3 needs T1's class but doesn't list it as dependency. Builder will hit a compile error.
- **Cyclic test dependency**: T2 needs a helper from T3, which needs a fixture from T2. Refactor: extract the shared bit to T0.
- **Phantom dependency**: T2 lists T1 as dependency, but they don't actually share code. Remove — wastes serialization.
