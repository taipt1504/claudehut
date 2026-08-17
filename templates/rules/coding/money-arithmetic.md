---
id: rules/coding/money-arithmetic
paths:
  - "**/*.java"
severity: critical
tags: [money, decimal, rounding, currency, arithmetic]
---
<!-- ClaudeHut rule template — generated into .claude/rules/coding/money-arithmetic.md by claudehut-init. -->

# Money Arithmetic Rule

Monetary bugs are silent: the code compiles, the tests pass on round numbers, and the ledger drifts by
fractions of a cent per transaction until a reconciliation run finds it.

## DO

- **`BigDecimal` for every monetary amount** — amounts, rates, fees, balances, totals.
- **Construct from `String` or `long` minor units**: `new BigDecimal("0.1")`, `BigDecimal.valueOf(10L, 2)`.
- **Always pass an explicit scale AND `RoundingMode`** when dividing or rounding:
  `a.divide(b, 2, RoundingMode.HALF_UP)`. Pick the mode the business specifies —
  `HALF_UP` for consumer-facing amounts, `HALF_EVEN` where regulators require banker's rounding.
- **Compare with `compareTo`, never `equals`** — `new BigDecimal("1.0").equals(new BigDecimal("1.00"))`
  is `false`, because `equals` compares scale as well as value.
- **Carry the currency with the amount.** An amount without its currency is not a monetary value; use a
  `Money`/`Amount` value object or `javax.money`, and refuse to add two different currencies.
- **Persist as `NUMERIC(19,4)`** (or the scale the domain requires) — never `float`/`double`/`real`.
- **Round once, at the boundary**, after the whole calculation; rounding intermediates compounds error.

## DON'T

- `double` or `float` for money — `0.1 + 0.2 != 0.3`, and the error scales with volume.
- `new BigDecimal(0.1)` from a `double` literal — captures the binary error
  (`0.1000000000000000055511151231257827021181583404541015625`). Use the `String` constructor.
- `divide()` with no scale — throws `ArithmeticException` on any non-terminating result (`1/3`).
- `setScale(2)` with no `RoundingMode` — throws when rounding is actually needed, so it passes tests on
  clean data and fails in production.
- Summing with `+` on `Long` cents in one place and `BigDecimal` in another; pick one representation.

## Enforcement

- A review that touches pricing, fees, interest, tax or balances must state the scale and `RoundingMode`.
- Property-based or table-driven tests over non-terminating cases (`1/3`, `0.005`, repeated addition of
  `0.1`), not only round numbers.
