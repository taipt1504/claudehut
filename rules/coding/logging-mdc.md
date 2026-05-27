---
id: rules/coding/logging-mdc
paths:
  - "**/*.java"
severity: medium
tags: [logging, mdc, observability]
---


# Logging + MDC

## DO

- Use SLF4J `Logger`. Get via Lombok `@Slf4j` or `LoggerFactory.getLogger(Class)`.
- Use structured logging (Logstash encoder).
- Populate MDC with `requestId`, `userId`, `tenantId` in filter.
- Log INFO for business events, DEBUG for technical details, WARN for recoverable failures, ERROR with stack for unrecoverable.
- Pass parameters as args (`log.info("Created user {}", id)`) — not string concat.

## DON'T

- `System.out.println` / `System.err.println`.
- `logger.info("..." + variable)` — string concat happens even if INFO disabled.
- Log inside hot loops without throttling.
- Log secrets (passwords, tokens, PII).
- Log full request bodies for endpoints with sensitive data.

## MDC setup (Servlet)

```java
@Component
public class MdcFilter extends OncePerRequestFilter {
    @Override
    protected void doFilterInternal(HttpServletRequest req, HttpServletResponse res, FilterChain chain)
            throws ServletException, IOException {
        try {
            String requestId = Optional.ofNullable(req.getHeader("X-Request-Id"))
                .orElseGet(() -> UUID.randomUUID().toString());
            MDC.put("requestId", requestId);
            MDC.put("path", req.getRequestURI());
            chain.doFilter(req, res);
        } finally {
            MDC.clear();
        }
    }
}
```

## MDC setup (WebFlux)

Use Reactor Context, not direct MDC.put:

```java
@Component
public class RequestContextFilter implements WebFilter {
    @Override
    public Mono<Void> filter(ServerWebExchange exchange, WebFilterChain chain) {
        String requestId = Optional.ofNullable(exchange.getRequest().getHeaders().getFirst("X-Request-Id"))
            .orElseGet(() -> UUID.randomUUID().toString());
        return chain.filter(exchange)
            .contextWrite(Context.of("requestId", requestId));
    }
}
```

Enable auto-propagation (Boot 3.2+):

```java
@PostConstruct
void init() { Hooks.enableAutomaticContextPropagation(); }
```

## logback-spring.xml (Logstash encoder)

```xml
<configuration>
    <appender name="JSON" class="ch.qos.logback.core.ConsoleAppender">
        <encoder class="net.logstash.logback.encoder.LoggingEventCompositeJsonEncoder">
            <providers>
                <timestamp/>
                <logLevel/>
                <loggerName/>
                <message/>
                <mdc/>
                <stackTrace/>
            </providers>
        </encoder>
    </appender>
    <root level="INFO">
        <appender-ref ref="JSON"/>
    </root>
</configuration>
```

## Log levels

| Level | When |
|-------|------|
| ERROR | Unrecoverable, user-impacting error. Always with stack. Triggers alert. |
| WARN | Recoverable failure, retry succeeded, deprecated API used. |
| INFO | Business events (user created, order placed, payment processed). |
| DEBUG | Technical detail (SQL params, request headers). |
| TRACE | Verbose (rarely enabled in prod). |

## Anti-patterns

- `log.error("user-related issue")` without exception → use WARN.
- INFO log per request × high QPS → log spam, sample instead.
- Logging password / token / API key — even via `toString()` if model has them.
- Logging full request body on file upload endpoints — huge logs.
