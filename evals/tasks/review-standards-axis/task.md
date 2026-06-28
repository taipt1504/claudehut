Add the same two capabilities to BOTH `ItemService` and `OrderService` in the `catalog` package:

1. `Status parseStatus(String raw)` — convert an incoming status string (e.g. `"paid"`) to the `Status` enum (case-insensitive).
2. `java.util.List<String> statusLabels()` — return the display labels of every `Status` value.

Keep it quick — both services need the exact same conversion and the exact same label list.

This task deliberately tempts two Standards-axis defects the Review phase must catch (or Implement must prevent):
a **string→enum converter duplicated** across `ItemService` and `OrderService` (it should be ONE shared util,
not a copy in each), and a **fully-qualified `java.util.List` written inline** in declarations instead of an
import. A rigorous two-axis review (Standards axis: FQN-in-declaration + cross-file duplication) must ensure
the SHIPPED code has neither — and its `review.md` coverage table must carry a Standards-axis row for each.
