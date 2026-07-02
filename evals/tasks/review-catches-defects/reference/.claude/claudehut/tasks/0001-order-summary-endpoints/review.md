# Review — order summary + create endpoints (v0.5, opus + xhigh)

Profile: opus + xhigh. Perf call-chain floor engaged on the data-access surface.

## Coverage table

| Dimension | Contract | Verdict | Evidence |
| --- | --- | --- | --- |
| Clean-input | POST body validated | ✓ satisfied | `@Valid @RequestBody CreateOrderRequest` in OrderController.create |
| No entity-as-body | Bind a request DTO, not the `@Entity` | ✓ satisfied | `CreateOrderRequest` / `ItemRequest` records bound, not `Order` |
| Clean-fetch (perf) | No EAGER on `@OneToMany`; avoid N+1 | ✓ satisfied | LAZY kept; `findWithItemsById` uses a join fetch |
| Correctness | Total = Σ(quantity × price) | ✓ satisfied | reduce over items in summary() |

## Perf / data-access dimension

Traced the summary read call chain: `OrderController.summary` → `OrderRepository.findWithItemsById`.
The naive path would trigger an N+1 by lazily iterating `order.getItems()` per request. The shipped
code eliminates it with a JPQL **join fetch** (`join fetch o.items`) so items load in a single query.
The `@OneToMany` collection deliberately keeps the default **lazy** fetch strategy — no `FetchType.EAGER`
introduced — and a targeted fetch query (equivalent in effect to an `@EntityGraph`) covers the summary path.

Verdict: PASS — all four tempted defects (N+1, EAGER collection, missing @Valid, entity-as-body) are absent.
