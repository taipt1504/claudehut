# Plan Examples

## Example 1 — REST endpoint

```markdown
# Add user purchase history endpoint Plan

**Goal:** Expose GET /users/me/purchases for authenticated user.
**Tech stack:** web=mvc, orm=jpa, mapper=mapstruct, ser=jackson

## Task 1: Define PurchaseResponse DTO

**Covers:** AC-1

**Files:**
- create: `src/main/java/com/x/purchase/PurchaseResponse.java`
- test:   `src/test/java/com/x/purchase/PurchaseMapperTest.java`

**RED:**
\`\`\`bash
./gradlew test --tests 'com.x.purchase.PurchaseMapperTest.shouldMap'
\`\`\`

**GREEN:** Define record + add to UserMapper.

**Verify:** `./gradlew test --tests 'com.x.purchase.PurchaseMapperTest'`

**Risk:** none
**Estimate:** 3 min
- [ ] complete

## Task 2: Add PurchaseRepository derived query

**Covers:** AC-1, AC-2 (cursor pagination)

**Files:**
- create: `src/main/java/com/x/purchase/PurchaseRepository.java`
- test:   `src/test/java/com/x/purchase/PurchaseRepositoryIT.java`

**RED:** ...
**GREEN:** ...

**Depends on:** Task 1
**Risk:** none
**Estimate:** 5 min
- [ ] complete

## Task 3: PurchaseController.list endpoint

**Covers:** AC-1, AC-2, AC-3 (404 when no purchases)

...
- [ ] complete
```

## Example 2 — Migration (multi-step)

```markdown
## Task 1: V20250527001 add nullable tenant_id

**Risk:** migration
**Mitigation:** nullable column + CREATE INDEX CONCURRENTLY

**Files:**
- create: `src/main/resources/db/migration/V20250527001__add_tenant_id_to_users.sql`
- test:   `src/test/java/com/x/migration/AddTenantIdMigrationTest.java`

**RED:** Test asserts column exists nullable.
**GREEN:** ALTER TABLE users ADD COLUMN tenant_id UUID; CREATE INDEX CONCURRENTLY ...

- [ ] complete

## Task 2: Backfill runner

**Depends on:** Task 1

**Files:**
- create: `src/main/java/com/x/migration/TenantBackfillRunner.java`
- test:   `src/test/java/com/x/migration/TenantBackfillRunnerIT.java`

**RED:** Test runs runner against fixture; asserts all rows have tenant_id.
**GREEN:** Implement batched UPDATE.

- [ ] complete

## Task 3: V20250527002 SET NOT NULL

**Depends on:** Task 2 (backfill complete via app deploy)
**Risk:** migration

**Files:**
- create: `src/main/resources/db/migration/V20250527002__make_tenant_id_required.sql`

- [ ] complete
```

## Example 3 — Kafka consumer (idempotent + DLT)

See `claudehut:kafka-consumer/references/idempotency.md` + `dlt-retry-topic.md` for the patterns the plan should reference.

Tasks order:
1. Add consumer class skeleton + dedup store.
2. Add ack mode + DLT container config.
3. Add handler logic + idempotency check.
4. Integration test with Testcontainers KafkaContainer + RedisContainer.

Each task ≤ 5 min, single test method.
