---
id: rules/coding/null-safety
paths:
  - "**/*.java"
severity: medium
tags: [null-safety, jsr-305, jspecify]
---
<!-- ClaudeHut rule template — generated into .claude/rules/coding/null-safety.md by claudehut-init. Reused & enhanced from committed rules/coding/null-safety.md. -->


# Null Safety

## Annotate public API

Use `@NonNull` / `@Nullable` from `javax.annotation` (JSR-305) or `org.jspecify` (modern).

```java
import jakarta.annotation.Nonnull;
import jakarta.annotation.Nullable;

public interface UserService {

    @Nonnull
    User findById(@Nonnull String id);  // never returns null; throws

    @Nullable
    User findByEmail(@Nonnull String email);  // may return null

    @Nonnull
    Optional<User> tryFindByEmail(@Nonnull String email);  // explicit optional
}
```

Better: use `Optional<T>` for optional returns; `@Nonnull` for guaranteed.

## DO

- Validate inputs at boundaries (controllers, public service methods).
- Use `Objects.requireNonNull(arg, "arg")` for fail-fast.
- Annotate public API for IDE + static analysis.
- Return `Optional<T>` instead of nullable returns from new code.
- Use `Map.getOrDefault`, `List.indexOf` → check `-1` instead of nullable.

## DON'T

- Return `null` from collection-returning methods — return empty collection.
- Pass `null` as method argument deliberately.
- `if (x != null) x.method()` — restructure to never have nullable x in scope.
- Use `Optional` as field/parameter.

## Examples

```java
// GOOD
public List<User> findActive() {
    var users = repo.findByActive(true);
    return users == null ? List.of() : users;
}

public User get(@Nonnull String id) {
    Objects.requireNonNull(id, "id");
    return repo.findById(id)
        .orElseThrow(() -> new NotFoundException("user", id));
}

// BAD
public List<User> findActive() {
    return repo.findByActive(true);  // could be null → NPE at caller
}

public User get(String id) {
    User u = repo.findById(id).orElse(null);  // hidden null
    return u.name();  // NPE
}
```

## Defensive copy of nullable param

```java
public Order(@Nullable List<OrderLine> lines) {
    this.lines = lines == null ? List.of() : List.copyOf(lines);
}
```

## Null in collections

- Don't insert `null` into `List<T>` — replaces a meaningful "absence" with implicit.
- Use sentinels or `Optional<T>` in collection if absence is meaningful.

## Static analysis

Enable SpotBugs + jsr305/jspecify annotations. Phase 5 verify gate catches violations.
