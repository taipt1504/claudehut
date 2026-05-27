---
id: rules/coding/optional-stream
applies-to: "**/*.java"
severity: medium
tags: [optional, stream, java]
---

# Optional + Stream Best Practices

## Optional

### DO

- Return `Optional<T>` from finder methods (`findById`, `findByEmail`).
- Chain with `.map`, `.filter`, `.orElse`, `.ifPresent`.
- Use `.orElseThrow(() -> new NotFoundException(id))` for required values.

### DON'T

- Use `Optional` as a field type.
- Use `Optional` as a method parameter.
- Use `Optional` in collections (`List<Optional<T>>`).
- Call `.get()` without prior `.isPresent()` check.

Examples:

```java
// GOOD
public Optional<User> findByEmail(String email) { ... }

User user = userRepo.findByEmail(email)
    .orElseThrow(() -> new NotFoundException(email));

userRepo.findByEmail(email)
    .map(User::name)
    .ifPresent(n -> log.info("Found: {}", n));

// BAD
public class User {
    private Optional<String> middleName;  // field is Optional → BAD
}

void process(Optional<User> user) { ... }  // param is Optional → BAD

User u = userRepo.findByEmail(email).get();  // .get() without check → BAD
```

## Stream

### DO

- Use `.toList()` (Java 16+) instead of `.collect(Collectors.toList())`.
- Use method references where they read clearer.
- Combine with records for projection.

### DON'T

- Reuse a Stream after terminal operation.
- Mutate external state in `.forEach`.
- Sort then collect when SortedMap would do.
- Use stream for trivial operations (single element transform; just call directly).

Examples:

```java
// GOOD
List<UserDto> dtos = users.stream()
    .filter(User::isActive)
    .map(UserMapper::toDto)
    .toList();

// BAD — collect into ArrayList unnecessary
List<UserDto> dtos = users.stream()
    .filter(u -> u.isActive())
    .map(u -> UserMapper.toDto(u))
    .collect(Collectors.toList());

// BAD — mutating external state
List<UserDto> dtos = new ArrayList<>();
users.stream().forEach(u -> {
    if (u.isActive()) dtos.add(mapper.toDto(u));  // anti-pattern
});
```

## Parallel streams

Don't use `.parallelStream()` unless:
- Collection size > 10,000.
- Operation per element is CPU-heavy.
- No shared state.

Default ForkJoinPool is shared — risky on small machines.

## Stream gotchas

- `.peek()` is for debugging, NOT for side effects.
- `.findFirst()` vs `.findAny()` — `findFirst` is ordered, `findAny` is faster for parallel.
- Collectors.toMap throws on duplicate key — provide merge function: `Collectors.toMap(k, v, (a, b) -> a)`.
