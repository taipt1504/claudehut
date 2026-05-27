# Worked Debug Sessions

## Table of contents

- [Session 1 — NPE in production](#session-1--npe-in-production)
- [Session 2 — Flaky integration test](#session-2--flaky-integration-test)
- [Session 3 — Wrong total in report](#session-3--wrong-total-in-report)

## Session 1 — NPE in production

**Report:** "Production: `UserService.create()` throws NPE when posting a request with no email field."

**Reproduce:**

```java
@Test
void shouldRejectMissingEmail_butDoesntCurrently() {
    var req = new CreateUserRequest(null, "Alice");
    assertThatThrownBy(() -> service.create(req))
        .isInstanceOf(IllegalArgumentException.class);
}
```

Runs locally → throws `NullPointerException` (wrong type). Reproduced.

**Bisect:** `git bisect` from 1 month ago. Identifies commit `abc123` — "refactor email normalization".

**Root cause:** In commit abc123, email normalization `email.toLowerCase().trim()` moved before null check. If email is null → NPE.

```java
// BEFORE
public User create(CreateUserRequest req) {
    if (req.email == null) throw new IllegalArgumentException("email required");
    var normalized = req.email.toLowerCase().trim();
    ...
}
// AFTER (the bug)
public User create(CreateUserRequest req) {
    var normalized = req.email.toLowerCase().trim();  // NPE here
    if (req.email == null) throw new IllegalArgumentException("email required");
    ...
}
```

**Test:** the failing test above already asserts correct behavior.

**Fix:** Move null check back before normalization.

**Commit:**

```
fix(user): null check before email normalization

NullPointerException when email field absent in CreateUserRequest.
Regressed in abc123 when normalization order changed.
```

## Session 2 — Flaky integration test

**Report:** "`OrderConsumerIT.shouldProcessOrderEvent` passes locally, fails in CI ~30% of the time."

**Reproduce locally:** Run in loop:

```bash
for i in {1..50}; do ./gradlew :integrationTest --tests OrderConsumerIT.shouldProcessOrderEvent; done
```

Fails ~15/50. Not deterministic but reproducible.

**Bisect inputs:** Suspect timing. Capture timestamps in test log.

**Observation:** Test produces event with `Instant.now()`. Consumer compares with `Instant.now()` at processing time. When CI is slow, processing instant > event instant by 100s ms → > clock skew threshold → reject.

**Root cause:** Consumer uses `Instant.now()` directly instead of injected `Clock`. Test can't control time.

**Test:** Refactor consumer to take `Clock`. Test with `Clock.fixed(...)`.

```java
@Test
void shouldProcessOrderEvent_withinClockSkew() {
    var fixedClock = Clock.fixed(Instant.parse("2025-01-01T00:00:00Z"), UTC);
    var consumer = new OrderConsumer(fixedClock, ...);
    var event = new OrderEvent(..., Instant.parse("2025-01-01T00:00:00.500Z")); // 500ms ahead
    consumer.process(event);
    assertProcessedSuccessfully();
}
```

**Fix:** Inject `Clock` into `OrderConsumer`; use `clock.instant()` instead of `Instant.now()`.

## Session 3 — Wrong total in report

**Report:** "Monthly report shows total = $9,847 but customer says actual is $9,851."

**Reproduce:** Pull customer's monthly data. Run report.

```bash
psql -c "SELECT SUM(amount) FROM orders WHERE customer_id=X AND created_at BETWEEN ... AND ...;"
```

Returns $9,851. Application returns $9,847. Discrepancy: $4.

**Bisect:** Compare SQL between SQL and application code path.

```java
// app code
return orders.stream()
    .map(Order::getAmount)
    .reduce(BigDecimal.ZERO, BigDecimal::add);
```

vs

```java
List<Order> orders = orderRepo.findByCustomer(...);
```

**Root cause:** `findByCustomer` uses `LIMIT 100`. Customer had 102 orders. Last 2 worth $4 total were excluded.

**Test:**

```java
@Test
void shouldSumAllOrders_notJustFirst100() {
    // arrange: 102 orders, each $1, total $102
    for (int i = 0; i < 102; i++) orderRepo.save(new Order(customer, BigDecimal.ONE));
    BigDecimal total = reportService.monthlyTotal(customer);
    assertThat(total).isEqualByComparingTo("102");
}
```

Failing — returns $100.

**Fix:** Remove `LIMIT` from repository method; or paginate properly in service.

```java
// repo
@Query("SELECT o FROM Order o WHERE o.customer = :c AND o.createdAt BETWEEN :from AND :to")
List<Order> findByCustomerInRange(...);  // no LIMIT
```
