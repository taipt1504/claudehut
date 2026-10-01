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

Use `@NonNull` / `@Nullable` from `org.jspecify.annotations` (JSpecify). Do **not** use JSR-305
(`javax.annotation`) — unmaintained, and the `javax` package is wrong on a Jakarta baseline.

```java
import org.jspecify.annotations.NonNull;
import org.jspecify.annotations.Nullable;

public interface UserService {

    @NonNull
    User findById(@NonNull String id);  // never returns null; throws

    @Nullable
    User findByEmail(@NonNull String email);  // may return null

    @NonNull
    Optional<User> tryFindByEmail(@NonNull String email);  // explicit optional
}
```

Better: use `Optional<T>` for optional returns; `@NonNull` for guaranteed.

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

public User get(@NonNull String id) {
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

Run a nullness checker that understands JSpecify (e.g. NullAway) in the build, so a violation fails the build.
