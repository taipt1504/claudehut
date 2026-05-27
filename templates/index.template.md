# Reusable Implementation Index

> Semantic map of reusable classes/modules in this project. Skills query this
> at Phase Brainstorm step 2 (reuse-scan) before suggesting new implementations.
>
> Maintenance: `claudehut:learn` skill appends entries automatically after each
> successful task. Manual edits welcome — keep entries one line each.

## Format

`- ClassName → path/to/File.java — one-line purpose`

---

## Domain: <domain-name>

<!-- e.g.
## Domain: User
- UserService → src/main/java/com/example/user/UserService.java — CRUD + duplicate-check
- UserRepository → src/main/java/com/example/user/UserRepository.java — JPA repository
-->

## Cross-cutting

<!-- e.g.
- TraceContextFilter → src/main/java/com/example/common/TraceContextFilter.java — adds traceId to MDC
- ProblemDetailHandler → src/main/java/com/example/common/ProblemDetailHandler.java — RFC 7807 errors
-->
