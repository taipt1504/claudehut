---
name: arch-unit-check
description: Run ArchUnit tests if present in project to enforce package-layout/hexagonal/DDD rules. Used in Phase 5 verify stage. Optional — skips if ArchUnit not on classpath. Slash-invoke /claudehut:arch-unit-check for ad-hoc verification.
---

# Arch-Unit Check

ArchUnit enforces architectural rules as tests. ClaudeHut integrates the runner.

## Quick start

```bash
/claudehut:arch-unit-check
```

Runs `scripts/run-archunit.sh`:

1. Detects ArchUnit on classpath (Gradle: `com.tngtech.archunit:archunit-junit5`).
2. If absent → exits 0 (skipped).
3. If present → runs ArchUnit test classes (typically tagged `@ArchTest` or in `archtest` source set).
4. Returns structured findings.

Common rules: `references/archunit-rules.md`.

## Scripts

- `scripts/run-archunit.sh` — gradle/maven runner.

## Standard rules ClaudeHut suggests

If your project uses hexagonal layout:

```java
@AnalyzeClasses(packages = "com.foo")
class ArchitectureTest {

    @ArchTest
    static final ArchRule domain_independent = noClasses()
        .that().resideInAPackage("..domain..")
        .should().dependOnClassesThat().resideInAnyPackage("..adapter..", "..application..", "..config..");

    @ArchTest
    static final ArchRule no_cycles = slices()
        .matching("com.foo.(*)..").should().beFreeOfCycles();

    @ArchTest
    static final ArchRule services_in_service_package = classes()
        .that().areAnnotatedWith(Service.class)
        .should().resideInAPackage("..service..");

    @ArchTest
    static final ArchRule controllers_dont_use_repositories_directly = noClasses()
        .that().areAnnotatedWith(RestController.class)
        .should().dependOnClassesThat().areAnnotatedWith(Repository.class);
}
```

## Hard rules

- Skip if ArchUnit not configured. Don't force it.
- Report violations but only Critical/High block phase advance.
- Don't auto-add ArchUnit rules — user-driven setup.

## Exit criteria

- [ ] ArchUnit run completed (or skipped explicitly)
- [ ] Violations reported in standard finding format
