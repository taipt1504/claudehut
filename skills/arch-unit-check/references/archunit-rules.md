# Common ArchUnit Rules

## Hexagonal layering

```java
@ArchTest
static final ArchRule domain_no_framework = noClasses()
    .that().resideInAPackage("..domain..")
    .should().dependOnClassesThat()
    .resideInAnyPackage("org.springframework..", "javax..", "jakarta..");
```

Domain layer must be framework-free.

```java
@ArchTest
static final ArchRule application_only_depends_on_domain_and_ports = classes()
    .that().resideInAPackage("..application..")
    .should().onlyAccessClassesThat()
    .resideInAnyPackage("..domain..", "..port..", "java..");
```

## Package cycle freedom

```java
@ArchTest
static final ArchRule no_package_cycles = slices()
    .matching("com.foo.(*)..").should().beFreeOfCycles();
```

## Naming + location

```java
@ArchTest
static final ArchRule services_in_service_package = classes()
    .that().areAnnotatedWith(Service.class)
    .should().resideInAPackage("..service..");

@ArchTest
static final ArchRule repositories_in_repository_package = classes()
    .that().areAnnotatedWith(Repository.class)
    .should().resideInAPackage("..repository..");

@ArchTest
static final ArchRule controllers_have_controller_suffix = classes()
    .that().areAnnotatedWith(RestController.class)
    .should().haveSimpleNameEndingWith("Controller");
```

## Dependency direction

```java
@ArchTest
static final ArchRule controllers_dont_use_repositories = noClasses()
    .that().areAnnotatedWith(RestController.class)
    .should().dependOnClassesThat().areAnnotatedWith(Repository.class);
```

Controllers must go through services.

## Forbidden patterns

```java
@ArchTest
static final ArchRule no_System_out = noClasses()
    .should().callMethod(System.class, "out");

@ArchTest
static final ArchRule no_join_point_in_domain = noClasses()
    .that().resideInAPackage("..domain..")
    .should().dependOnClassesThat()
    .haveFullyQualifiedName("org.springframework.transaction.annotation.Transactional");
```

## Method size

ArchUnit doesn't directly count lines, but combined with PMD/Checkstyle:

- Method > 80 lines → PMD `ExcessiveMethodLength` rule.
- Class > 500 lines → PMD `ExcessiveClassLength` rule.

## Custom domain rules

```java
@ArchTest
static final ArchRule aggregate_roots_only_in_domain = classes()
    .that().areAssignableTo(AggregateRoot.class)
    .should().resideInAPackage("..domain..");

@ArchTest
static final ArchRule events_are_immutable = classes()
    .that().haveSimpleNameEndingWith("Event")
    .should().haveOnlyFinalFields();
```

## How rules surface in CI

ArchUnit tests run as normal JUnit tests. Phase 5 verify gate `./gradlew test` will pick them up automatically. ClaudeHut's reviewer-style cross-references findings with the changed files.
