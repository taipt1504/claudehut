---
id: rules/framework/virtual-threads
paths:
  - "**/application*.yml"
  - "**/application*.properties"
  - "**/*Config.java"
  - "**/*Executor*.java"
severity: medium
tags: [virtual-threads, loom, java21]
---
<!-- ClaudeHut rule template — generated into .claude/rules/framework/virtual-threads.md by claudehut-init. Reused & enhanced from committed rules/framework/virtual-threads.md. -->


# Spring Virtual Threads (Project Loom)

**Requires:** Java 21+. Java 24+ strongly recommended (see Pinning section).

## Enable

```yaml
# application.yml — Spring Boot 3.2+
spring:
  threads:
    virtual:
      enabled: true
  main:
    keep-alive: true   # virtual threads are daemon threads; without this JVM exits immediately
```

**What `spring.threads.virtual.enabled=true` switches on:**

| Component | Effect |
|---|---|
| Tomcat | `VirtualThreadExecutor` on protocol handler (request threads) |
| Jetty | `server.jetty.virtual-threads.enabled` is a separate property — set both |
| `@Async` / `ApplicationTaskExecutor` | `SimpleAsyncTaskExecutor` with virtual threads (replaces `ThreadPoolTaskExecutor`) |
| Spring MVC async, GraphQL `Callable` | Inherits from `ApplicationTaskExecutor` |
| WebFlux | **Not changed** — reactive scheduler is unaffected |

## When NOT to enable

| Scenario | Reason |
|---|---|
| CPU-bound work (compression, crypto, ML inference) | Virtual threads don't add parallelism — platform thread count is still the ceiling |
| WebFlux (reactive) apps | Two concurrency models in one JVM; don't mix |
| JDK < 21 | `spring.threads.virtual.enabled` is silently ignored |
| Workloads with no blocking I/O | No benefit; adds context-switch overhead |

## Pinning — the silent performance trap

A virtual thread is **pinned** (blocks its carrier platform thread) when it parks inside a `synchronized` block that contains blocking I/O. Pre-JDK 24 this negates all virtual-thread benefit in the pinned section.

**JDK version table:**

| JDK | Pinning behaviour |
|---|---|
| 21–23 | `synchronized` + blocking I/O pins carrier; concurrent virtual threads stall |
| 24+ | JEP 491 removes most pinning — `synchronized` unmounts from carrier like `ReentrantLock` |

**Detect pinning (JDK 21–23):**

```
-Djdk.tracePinnedThreads=full
```

Outputs a stack trace whenever a virtual thread pins. Add to JVM args during load testing.

**Fix — replace synchronized-with-blocking-IO:**

```java
// BEFORE (pins carrier on JDK < 24)
synchronized (this) {
    result = jdbcTemplate.queryForObject(...);
}

// AFTER
private final ReentrantLock lock = new ReentrantLock();

lock.lock();
try {
    result = jdbcTemplate.queryForObject(...);
} finally {
    lock.unlock();
}
```

## Connection pools become the real ceiling

With virtual threads you can have **thousands of concurrent DB calls** in flight.  
HikariCP default: `maximumPoolSize = 10`.

**Failure mode in prod:** request latency spikes, `HikariPool-1 - Connection is not available, request timed out after 30000ms` — looks like slow queries, is actually pool exhaustion.

```yaml
spring:
  datasource:
    hikari:
      maximum-pool-size: 20      # size to what the DB can actually handle, not thread count
      connection-timeout: 5000   # fail fast; default 30 000 ms hides saturation
```

**Formula:** `pool_size ≈ (DB max_connections × 0.8) / app_instance_count`

**Prefer a semaphore over thread-count limits** when you need to bound DB concurrency:

```java
private static final Semaphore DB_PERMITS = new Semaphore(20);

DB_PERMITS.acquire();
try {
    return repo.findById(id);
} finally {
    DB_PERMITS.release();
}
```

This caps in-flight DB calls without capping threads; virtual threads waiting on the semaphore unmount from the carrier.

## Don't pool virtual threads

```java
// CORRECT
ExecutorService exec = Executors.newVirtualThreadPerTaskExecutor();

// WRONG — defeats the model; fixed pool starves under load like platform threads
ExecutorService exec = Executors.newFixedThreadPool(200, Thread.ofVirtual().factory());
```

Spring Boot's auto-configured `SimpleAsyncTaskExecutor` already does the right thing when virtual threads are enabled — don't define a competing `Executor` bean unless you have a specific reason.

## ThreadLocal at scale

Every virtual thread gets its own `ThreadLocal` copy. At 100 k concurrent threads, `ThreadLocal` objects holding large state multiply memory by thread count.

- Prefer `ScopedValue` (JDK 21 preview → standard in later releases) <!-- [uncertain: ScopedValue finalized JDK version — verify before use] --> for read-only context propagation.
- Audit `ThreadLocal` bearers (MDC, security context, tenant ID) — Spring's `TaskDecorator` copies MDC automatically when using `SimpleAsyncTaskExecutor`.

## Anti-patterns

| Anti-pattern | Failure mode |
|---|---|
| `synchronized` + JDBC on JDK 21–23, no mitigation | Carrier pinning, throughput collapses under load |
| HikariCP default pool size with VT enabled | Pool exhaustion masquerades as query slowness |
| Fixed `ThreadPool` of virtual threads | Same starvation as platform threads, wastes the model |
| Enabling VT in WebFlux app | Two schedulers fight; unpredictable latency |
| `ThreadLocal` holding large objects at high concurrency | OOM / GC pressure proportional to virtual thread count |
