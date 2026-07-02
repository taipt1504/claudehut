# Review — parseStatus / statusLabels on ItemService + OrderService

Two-axis review: Correctness axis + Standards axis.

## Coverage table

| Axis | Concern | Verdict | Evidence |
|------|---------|---------|----------|
| Correctness | parse maps "paid" → Status.PAID case-insensitively | ✓ | StatusConverter.parse trims + toUpperCase before valueOf |
| Correctness | statusLabels returns all Status values | ✓ | StatusConverter.labels streams Status.values() |
| Standards | cross-file duplication of string→enum converter | ✓ | conversion logic lives ONLY in StatusConverter; both services delegate via StatusConverter.parse — no copy |
| Standards | fully-qualified `java.util.List` (FQN) in declarations | ✓ | `java.util.List` is imported, not written inline; declarations use `List<String>` |
| Standards | naming / convention consistency | ✓ | method names and package convention match existing catalog services |

## Outcome

Both Standards-axis defects the task tempted (duplicated converter, inline FQN) were prevented by centralizing
into `StatusConverter` and importing `java.util.List`. Shipped tree is clean on both.
