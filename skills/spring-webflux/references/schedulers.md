# Schedulers

## Built-in schedulers

| Scheduler | When to use |
|-----------|-------------|
| `Schedulers.parallel()` | CPU-bound short work (default for non-blocking ops) |
| `Schedulers.boundedElastic()` | Blocking I/O (legacy JDBC, file, RestTemplate calls wrapped in Mono.fromCallable) |
| `Schedulers.single()` | Single-threaded — for serializing state |
| `Schedulers.immediate()` | No thread switch (default if not specified) |
| Custom | Specific tuning needed |

## Wrap blocking call

```java
public Mono<String> blockingCall(String input) {
    return Mono.fromCallable(() -> legacyClient.callBlocking(input))
        .subscribeOn(Schedulers.boundedElastic());
}
```

`fromCallable` defers the blocking work. `subscribeOn(boundedElastic)` runs it on a thread suitable for blocking.

## When parallel vs boundedElastic

- `parallel()` has fixed CPU-count threads. Saturate them with blocking work → throughput dies.
- `boundedElastic()` has up to 10× CPU threads, queue up to 100k tasks. Designed for blocking work.

## Custom scheduler for sensitive operations

```java
@Bean
public Scheduler dbScheduler() {
    return Schedulers.newBoundedElastic(20, Integer.MAX_VALUE, "db", 60);
}
```

Use named schedulers for observability (thread name shows in logs).

## Disposable schedulers

Always dispose custom schedulers in `@PreDestroy`:

```java
@PreDestroy
public void shutdown() {
    dbScheduler.dispose();
}
```

## subscribeOn vs publishOn

- `subscribeOn` — affects the SOURCE of the chain. Use it ONCE at the top.
- `publishOn` — switches thread for OPERATORS downstream of it. Use to control where transformations run.

```java
Mono.fromCallable(this::blockingFetch)         // runs on the scheduler from subscribeOn
    .subscribeOn(Schedulers.boundedElastic())  // ↑
    .map(this::cpuTransform)                   // also on boundedElastic
    .publishOn(Schedulers.parallel())          // ↓ switch to parallel
    .map(this::moreCpuTransform);              // on parallel now
```

## Common mistake

```java
// BAD — wraps blocking call but doesn't isolate the scheduler
Mono.fromCallable(this::blockingCall)
    .subscribeOn(Schedulers.parallel());  // saturates CPU-bound pool
```

Use `boundedElastic` for blocking. `parallel()` is for CPU-bound code.
