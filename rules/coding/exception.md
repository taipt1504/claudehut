---
id: rules/coding/exception
applies-to: "**/*.java"
severity: high
tags: [exception, error-handling]
---

# Exception Handling

## DO

- Define custom domain exceptions extending a project-base abstract class.
- Throw early at input boundaries.
- Catch only what you can handle.
- Wrap checked exceptions at boundaries (don't propagate `IOException` from service to controller).
- Use try-with-resources for `AutoCloseable`.
- Log AT exception origin OR at handler — not both (avoids duplicate log entries).

## DON'T

- `catch (Exception e)` or `catch (Throwable t)` in production code — too broad, hides bugs.
- `e.printStackTrace()` — use logger.
- Swallow exception: `catch (Exception e) {}` empty block.
- Throw raw `RuntimeException("...")` — use specific subtype.
- Throw checked exceptions from interfaces (lambda-unfriendly).
- Use exceptions for control flow (`if`/`else` is faster + clearer).

## Domain exception hierarchy

```java
public abstract class DomainException extends RuntimeException {
    private final String code;
    protected DomainException(String code, String message) {
        super(message);
        this.code = code;
    }
    protected DomainException(String code, String message, Throwable cause) {
        super(message, cause);
        this.code = code;
    }
    public String code() { return code; }
}

public class NotFoundException extends DomainException {
    public NotFoundException(String resource, String id) {
        super("not-found", resource + " not found: " + id);
    }
}

public class DuplicateException extends DomainException {
    public DuplicateException(String resource, String key) {
        super("duplicate", resource + " already exists: " + key);
    }
}

public class BusinessRuleException extends DomainException {
    public BusinessRuleException(String rule, String detail) {
        super("business-rule:" + rule, detail);
    }
}
```

## REST integration

```java
@RestControllerAdvice
public class GlobalExceptionHandler {

    @ExceptionHandler(NotFoundException.class)
    public ProblemDetail handleNotFound(NotFoundException ex) {
        var p = ProblemDetail.forStatus(HttpStatus.NOT_FOUND);
        p.setType(URI.create("urn:problem:" + ex.code()));
        p.setDetail(ex.getMessage());
        return p;
    }

    @ExceptionHandler(DuplicateException.class)
    public ProblemDetail handleDuplicate(DuplicateException ex) {
        var p = ProblemDetail.forStatus(HttpStatus.CONFLICT);
        p.setType(URI.create("urn:problem:" + ex.code()));
        p.setDetail(ex.getMessage());
        return p;
    }
}
```

## Logging

```java
// GOOD — log + throw, OR rethrow without log
try { ... }
catch (Exception e) {
    log.error("operation X failed", e);
    throw new DomainException("X failed", e);
}

// BAD — double logging
try { ... }
catch (Exception e) {
    log.error("X failed", e);
    throw e;  // caller logs again → 2 stack traces in logs
}
```

## Wrap external exceptions

```java
public User findById(String id) {
    try {
        return externalClient.getUser(id);
    } catch (HttpClientException ex) {
        throw new ExternalServiceException("user-api", "lookup failed for " + id, ex);
    }
}
```
