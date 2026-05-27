# Risk Callout Taxonomy

Tag each task. If multiple, list multiple tags.

| Tag | Meaning | Mitigation expected |
|-----|---------|---------------------|
| `migration` | Schema/data change in production DB | Backward compat, CONCURRENTLY, batch backfill, rollback plan |
| `breaking-api` | Changes public API contract | Version + deprecation window OR coordination with callers |
| `security` | Touches auth, validation boundary, secret handling | Reviewer-security must approve |
| `perf-hot-path` | On request critical path with strict SLA | Benchmark before merge |
| `external-deps` | Adds a new external service dependency | Health check + circuit breaker + fallback |
| `cross-module` | Touches > 1 module/package | Verify compile + test of all touched modules |
| `irreversible` | Hard to revert (e.g., DROP COLUMN) | Backup + tested rollback procedure |
| `concurrency` | Touches lock, atomic, race-prone code | Concurrent test required |
| `none` | No special risk | (no extra mitigation needed) |

## Mitigation format

```markdown
**Risk:** migration, perf-hot-path
**Mitigation:**
- CREATE INDEX CONCURRENTLY (no table lock)
- Backfill in batches of 10k with sleep(100ms) between batches
- Run during low-traffic window (defined in runbook)
- Have prior column-add SQL ready to rollback
```

## When tagging

- Default `none` if no obvious risk.
- ANY DB schema change → `migration`.
- ANY change to `@RequestMapping`, `@KafkaListener` topic name, gRPC proto → `breaking-api`.
- ANY change in `SecurityConfig`, `WebSecurityConfig`, auth filter → `security`.
- ANY new dependency in `build.gradle` or `pom.xml` → `external-deps`.
