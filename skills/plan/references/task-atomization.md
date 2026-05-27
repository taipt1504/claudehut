# Task Atomization Heuristics

## The 2–5 minute rule

A task is correctly sized when:

- A skilled engineer can finish it in 2–5 minutes (focused).
- It produces a single commit.
- The verify command is one line.
- The diff fits in your head — < 50 lines net change.

## When a task is too big

Signs:

- The verify command runs > 1 test.
- The diff spans > 2 source files (+ tests).
- The task has multiple "AND" outcomes.

Split by:

1. Each AC criterion → its own task.
2. Each invalid-input path → its own task.
3. Each interface signature → defined in one task, implemented in next.

## When a task is too small

Signs:

- The task is a no-op (e.g., "add @SuppressWarnings").
- The verify command exits 0 immediately.

Merge with:

- A neighbour task that depends on it.
- An adjacent test in the same class.

## Standard task shapes

### Add a class with one method

```markdown
## Task: Implement FooService.create

Files:
- create: src/main/java/com/x/FooService.java
- test:   src/test/java/com/x/FooServiceTest.java

RED:
  ./gradlew test --tests 'com.x.FooServiceTest.shouldCreateFoo'
  # expect FAIL: NoSuchMethodError

GREEN:
  Add FooService class with create(FooRequest) returning FooResponse.

Verify:
  ./gradlew test --tests 'com.x.FooServiceTest.shouldCreateFoo'
```

### Modify existing class

```markdown
## Task: Add duplicate-check to FooService.create

Files:
- modify: src/main/java/com/x/FooService.java
- test:   src/test/java/com/x/FooServiceTest.java (add method)

RED:
  ./gradlew test --tests 'com.x.FooServiceTest.shouldRejectDuplicate'
  # expect FAIL

GREEN:
  In FooService.create, call repository.existsByEmail and throw
  DuplicateFooException when true.

Verify:
  ./gradlew test --tests 'com.x.FooServiceTest'
```

### Migration task

```markdown
## Task: Flyway migration V20250527001 — add tenant_id column

Files:
- create: src/main/resources/db/migration/V20250527001__add_tenant_id.sql
- test:   src/test/java/com/x/MigrationTest.java (add method)

RED:
  ./gradlew test --tests 'com.x.MigrationTest.shouldAddTenantIdColumn'

GREEN:
  ALTER TABLE users ADD COLUMN tenant_id BIGINT;
  CREATE INDEX CONCURRENTLY idx_users_tenant_id ON users(tenant_id);

Verify:
  ./gradlew test --tests 'com.x.MigrationTest'

Risk: migration on production table (50M rows). Mitigation:
  CREATE INDEX CONCURRENTLY + nullable column + separate backfill task.
```
