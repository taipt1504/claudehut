# Reproduce Protocol

## Goal

Make the bug deterministic. If you can't reproduce, you can't fix.

## Steps

### 1. Capture the report

- Exact error message + stack trace.
- Exact input (request body, params, event payload).
- Exact state (DB row state, cache contents, time-of-day).
- Exact version (commit SHA, deployed image tag).

### 2. Try direct reproduction

- Boot the app locally.
- Replay the exact input.
- Does it fail? If yes → done with this step.

### 3. If not reproducing locally

Bug depends on external state. Capture that state:

- **Time-dependent:** test with `Clock.fixed(...)` or freeze-time.
- **DB-state-dependent:** snapshot the affected rows; restore in test.
- **Race condition:** run in a tight loop; check thread-dump on hang.
- **Network-dependent:** use WireMock to replay external responses.
- **Memory-dependent:** check heap-dump for the pattern.

### 4. Boil down to minimal test

Once reproducing reliably:

- Write the SMALLEST test that exhibits the bug.
- Strip everything that isn't necessary.
- Don't worry about prettiness yet.

### 5. Move to test suite

- Place the minimal test in the appropriate test file.
- Naming: `should<correct behavior>_when<bug condition>`.
- Mark with `@DisplayName` if convoluted.
- Commit the failing test ON ITS OWN.

## Anti-patterns

- "Works on my machine" → not reproduced. Capture state difference.
- "Sometimes fails" → flaky. Run 1000× in loop to see the rate.
- "Probably the DB" → guessing. Capture the actual state.
- Skipping minimal test step → fix touches more than needed.

## Reproduction recipes

### Race condition

```java
@Test
void shouldNotCorrupt_underConcurrentAccess() throws InterruptedException {
    int threads = 50;
    var latch = new CountDownLatch(threads);
    var errors = new ConcurrentLinkedQueue<Throwable>();
    var exec = Executors.newFixedThreadPool(threads);
    for (int i = 0; i < threads; i++) {
        exec.submit(() -> {
            try { service.method(); } catch (Throwable t) { errors.add(t); }
            finally { latch.countDown(); }
        });
    }
    latch.await(10, TimeUnit.SECONDS);
    assertThat(errors).isEmpty();
}
```

### Time-dependent

```java
@Test
void shouldExpire_afterTtl() {
    var clock = Clock.fixed(Instant.parse("2025-01-01T00:00:00Z"), ZoneOffset.UTC);
    var service = new FooService(clock);
    var token = service.issue();
    // advance time
    var future = Clock.offset(clock, Duration.ofMinutes(31));
    assertThat(service.isValid(token, future.instant())).isFalse();
}
```

### Network-dependent

```java
@Test
void shouldRetry_onTransient5xx() {
    wireMock.stubFor(get("/api/x")
        .inScenario("retry")
        .whenScenarioStateIs(STARTED)
        .willReturn(serverError())
        .willSetStateTo("second"));
    wireMock.stubFor(get("/api/x")
        .inScenario("retry")
        .whenScenarioStateIs("second")
        .willReturn(ok()));
    var result = client.get();
    assertThat(result.statusCode()).isEqualTo(200);
}
```
