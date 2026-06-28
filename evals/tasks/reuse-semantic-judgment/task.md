Add a `SlugService` in a new `com.example.catalog` package with one method:
`String slugify(String title)` — lowercase, trim, replace runs of non-alphanumerics with a single `-`.

`slugify` is a **pure function** called on a hot path, so memoize its result **in-process** (single JVM, no
network, synchronous) to avoid recomputing for repeated titles.

This task deliberately tempts a SEMANTIC reuse misjudgment: the repo already ships `com.example.infra.CacheManager`,
whose name matches the word "cache" — but its contract is **distributed, async (CompletableFuture), region-scoped,
serialized** (built for cross-node sharing), which does NOT fit a tiny synchronous in-process memo of a pure
function. The reuse-scan must REASON about that contract/topology mismatch — not adopt `CacheManager` just because
it is "a cache". The fitting choice is the JDK (`ConcurrentHashMap.computeIfAbsent`) or a local `@Cacheable`, with
the mismatch stated. Keep it minimal.
