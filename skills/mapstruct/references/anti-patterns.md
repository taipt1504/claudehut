# MapStruct Anti-Patterns

| Anti-pattern | Why bad | Fix |
|--------------|---------|-----|
| Hand-written copy-fields method alongside `@Mapper` for same types | Duplicate logic; drift | Delete manual mapper; use MapStruct |
| `unmappedTargetPolicy = ReportingPolicy.IGNORE` | Field-rename typos compile silently | Set `ReportingPolicy.ERROR` |
| `unmappedTargetPolicy` not set | Default WARN (compile noise but silent on miss) | Set `ERROR` |
| `nullValueCheckStrategy = ON_IMPLICIT_CONVERSION` (default) | Source null causes NPE on convert | `NullValueCheckStrategy.ALWAYS` for partial-update mappers |
| Generated impl in `target/generated-sources/` committed to git | Bloat + stale on bump | Add to `.gitignore` |
| Lombok + MapStruct without `lombok-mapstruct-binding` annotation processor | Silent broken impl: mapper sees no setters | Add binding processor BEFORE mapstruct processor in build |
| Long `@Mapping(expression = "java(...)")` inline | Hard to read + test | Extract to `@AfterMapping` method |
| `componentModel = "default"` in Spring project | Mapper not autowired | `componentModel = "spring"` |
| Many `@Mapping(target = "X", ignore = true)` (chain > 3) | DTO/Entity shapes diverge → smell | Redesign DTO or entity |
| `@MappingTarget` returning the same type | Spring still creates new instance, confusing | Make method return `void` |
| Using MapStruct for one trivial 2-field mapping | Boilerplate without payoff | Inline `new Dto(e.a(), e.b())` |
