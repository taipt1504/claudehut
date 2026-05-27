# Given/When/Then Acceptance Criteria

## Format

```
GIVEN <precondition / system state>
WHEN  <single action under test>
THEN  <single observable outcome>
AND   <optional secondary outcome>
```

Each criterion = exactly one test method. If you need "AND" with a different observable, write a separate criterion.

## Examples

### REST endpoint

```
AC-1
GIVEN authenticated user "u1" with no purchases
WHEN  GET /users/me/purchases?cursor=null&size=20
THEN  HTTP 200 returned
AND   body.items is empty array
AND   body.nextCursor is null
```

```
AC-2
GIVEN unauthenticated request
WHEN  GET /users/me/purchases
THEN  HTTP 401 returned
AND   body is ProblemDetail with type=urn:auth-required
```

### Kafka consumer

```
AC-3
GIVEN event "order.created" with orderId=42 already processed (in EventDedupStore)
WHEN  same event arrives again
THEN  no new ShippingJob created
AND   message acked
AND   metric `events_deduped_total` incremented by 1
```

### Data migration

```
AC-4
GIVEN existing user rows with NULL tenant_id
WHEN  V20250527002 backfill migration runs
THEN  all rows have tenant_id matching organization.tenant_id
AND   migration completes within 10 minutes for 50M rows
AND   no row-level locks held longer than 100ms
```

## Anti-patterns

- **Multiple WHEN steps**: split into multiple criteria.
- **Vague THEN**: "returns success" → specify status code, body shape.
- **Implementation-coupled**: "service.create() called once" → test behavior, not implementation.
- **Hidden state**: GIVEN should make all relevant preconditions explicit.

## Coverage rule

For each public method/endpoint, MUST have:

- ≥ 1 happy path
- ≥ 1 invalid-input path
- ≥ 1 boundary path (empty, max, null where allowed)
- ≥ 1 downstream-failure path (if downstream exists)
