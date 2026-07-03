# rest — summer-rest-autoconfigure, summer-rest-common
> Consumer-facing: yes · Auto-config: default-on · Depends on: core

## TL;DR
- Drop `summer-rest-autoconfigure` on the classpath → error handler + Jackson policy + WebFlux formatters/resolvers wire themselves; you write no config for defaults.
- Signal domain errors by throwing Summer exceptions (`ViewableException`/`CommonExceptions`); the reactive `@Order(-2)` handler renders a uniform `{code,message,traceId,details}` JSON body.
- OpenAPI (`f8a.common.api-doc.enabled`) and request/response access logging (`summer.http.logging.enabled`) are the only two pieces OFF by default.

## Activate
Gradle: `implementation "io.f8a.summer:summer-rest-autoconfigure"` (pulls `summer-rest-common` → `summer-core` transitively). The `.imports` file lists 3 auto-configs; `EnableAllAutoConfig` (nested in `SummerRestAutoConfiguration`) `@Import`s the rest — incl. `JacksonAutoConfiguration`, which is NOT in the `.imports` file.

| Auto-config / bean | Gate property | Default | Notes |
|---|---|---|---|
| `SummerRestAutoConfiguration` (class) | — | on | class-gated `@ConditionalOnClass(SpringBootApplication)`; enables `CommonLibProperties`+`HttpLoggingProperties` |
| ↳ `EnableAllAutoConfig` | `f8a.common.enabled` | on (`matchIfMissing=true`) | master switch; `@Import`s the 6 nested configs below |
| ↳ `ExceptionHandlingAutoConfig` (REACTIVE) | `f8a.common.exception-handling.enabled` | on | → `SummerGlobalExceptionHandler` |
| ↳ `ServletExceptionHandlingAutoConfig` (SERVLET) | `f8a.common.exception-handling.enabled` | on | → `SummerServletExceptionHandler` (servlet apps only) |
| ↳ `WebClientAutoConfig` | `f8a.common.webclient.enabled` | on | `@ConditionalOnClass(WebClient)` → `WebClientBuilderFactory` |
| ↳ `RequestLoggingAutoConfig` (REACTIVE) | `summer.http.logging.enabled` | **off** (`matchIfMissing=false`) | → `RequestLoggingWebFilter` |
| ↳ `JacksonAutoConfiguration` | `f8a.common.jackson.enabled` | on | → `Jackson2ObjectMapperBuilderCustomizer` |
| `SummerApiDocAutoConfiguration` | `f8a.common.api-doc.enabled` | **off** (`matchIfMissing=false`) | → `OpenAPI`, `OpenApiCustomizer`, `ApiDocController`, `SpringDocPropertyCustomizer` |
| `SummerWebfluxConfiguration` | — (ungated) | **always on** | `WebFluxConfigurer`: `Txid`/`Ufid` converters, reactive paging resolvers, `RequestInfoWebFilter` |

## Config keys
Bound by `CommonLibProperties` (`f8a.common.*`, in summer-core) + `HttpLoggingProperties` (`summer.http.logging.*`).

| Key | Default | Purpose |
|---|---|---|
| `f8a.common.enabled` | `true` | master switch for `EnableAllAutoConfig` |
| `f8a.common.jackson.enabled` | `true` | whole Jackson customizer on/off (sub-keys below are INERT — see Gotchas) |
| `f8a.common.exception-handling.enabled` | `true` | global/servlet error handler on/off |
| `f8a.common.exception-handling.include-stack-trace` | `false` | **INERT** — bound but no handler reads it; stack trace is never written to the body |
| `f8a.common.exception-handling.include-binding-errors` | `true` | **INERT** — field-level validation `details` are always included regardless |
| `f8a.common.webclient.enabled` | `true` | `WebClientBuilderFactory` bean on/off (gate is spelled `webclient`) |
| `f8a.common.web-client.connect-timeout` | `10s` | connect timeout |
| `f8a.common.web-client.read-timeout` | `30s` | read timeout |
| `f8a.common.web-client.max-connections` | `100` | pool size (`connection-pool-name` = `summer-webclient-pool`) |
| `f8a.common.web-client.max-idle-time` / `max-life-time` / `pending-acquire-timeout` | `30s` / `5m` / `60s` | pool lifecycle |
| `f8a.common.web-client.proxy.enabled` | `true` | proxy handling (no-op unless JVM proxy props set) |
| `f8a.common.web-client.proxy.use-system-properties` | `true` | use JVM `http(s).proxyHost/Port`; `false` → use explicit `host`/`port`/`type`/`username`/`password`/`non-proxy-hosts` |
| `f8a.common.api-doc.enabled` | `false` | turn on OpenAPI + `ApiDocController` |
| `f8a.common.api-doc.title` / `version` / `description` | `"API Documentation"` / `1.0.0` / … | OpenAPI `Info` fields (also `contact-*`, `license-*`, `server-url`, `terms-of-service-url`) |
| `f8a.common.api-doc.swagger-ui.path` | `/swagger-ui.html` | Swagger UI path (`swagger-ui.*`, `open-api.*` further tune paths) |
| `summer.http.logging.enabled` | `false` | access-logging `RequestLoggingWebFilter` |
| `summer.http.logging.log-headers` | `false` | log masked request headers at DEBUG |

## Public API
| Type | When to use |
|---|---|
| `SummerGlobalExceptionHandler` (reactive, `@Order(-2)`) | never call — it maps thrown exceptions; declare your own bean only to override mapping |
| `SummerServletExceptionHandler` | servlet stack equivalent; same override rule |
| `WebClientBuilderFactory` | inject to build an outbound reactive `WebClient` with log+error filters (declared in summer-core, wired here — see core.md) |
| `ApiDocController` (`/api/docs/info`, `/api/docs/health`) | reachable only when `api-doc.enabled=true`; no code needed |
| `SpringDocPropertyCustomizer` | auto-applies `api-doc.*` to springdoc; override by supplying your own bean |
| `ViewableException` / `CommonExceptions` (summer-core) | throw to produce a mapped JSON error (`CommonExceptions.RESOURCE_NOT_FOUND.toException()`) |
| `ApiResponse<T>` (summer-core) | wrap success payloads: `ApiResponse.success(dto)` |
| `Txid` / `Ufid` (summer-core) | use directly as `@PathVariable`/`@RequestParam` type — string→type conversion is registered |

## Usage
```java
// Txid/Ufid convert from the path automatically (SummerWebfluxConfiguration formatters)
@GetMapping("/parties/{id}")
Mono<ApiResponse<PartyResponse>> get(@PathVariable Ufid id) {
  return service.find(id)
      .switchIfEmpty(Mono.error(CommonExceptions.RESOURCE_NOT_FOUND.toException()))
      .map(ApiResponse::success);
}
```
```yaml
f8a:
  common:
    api-doc: { enabled: true, title: party-ms API, version: 1.0.0 }  # OFF by default
summer:
  http:
    logging: { enabled: true }   # RequestLoggingWebFilter (REACTIVE only), OFF by default
```

## Gotchas
- `SummerGlobalExceptionHandler` is `@Order(-2)` to beat Spring's `DefaultErrorWebExceptionHandler`; it never forwards downstream errors — `DownstreamException` → `CommonExceptions.DOWNSTREAM_SERVICE_ERROR`, any unmapped throwable → `INTERNAL_SERVER_ERROR`.
- `traceId` in the error body is read from SLF4J `MDC.get("traceId")` — null if MDC isn't populated upstream.
- Status mapping (switch): `MethodArgumentNotValidException`/`WebExchangeBindException`/`ServerWebInputException`/`IllegalArgumentException` → 400 `INVALID_REQUEST` (+field `details`); `IllegalStateException`/`DuplicateKeyException`/`OptimisticLockingFailureException` → 409 `CONFLICT`; `AccessDeniedException` → 403; `AuthenticationException` → 401; `NoResourceFoundException` → `RESOURCE_NOT_FOUND`.
- Jackson is applied via a `Jackson2ObjectMapperBuilderCustomizer` (customizes Boot's builder, does NOT replace the `ObjectMapper` bean): `JavaTimeModule`+`Jdk8Module`+`ParameterNamesModule`, disables `WRITE_DATES_AS_TIMESTAMPS`+`FAIL_ON_UNKNOWN_PROPERTIES`, enums-as-`toString`, `NON_NULL`, `LOWER_CAMEL_CASE`, UTC.
- **`f8a.common.jackson.*` sub-keys (write-dates-as-timestamps, property-naming-strategy, date-format, …) are INERT** — the customizer hardcodes behavior; only `f8a.common.jackson.enabled=false` changes anything (disables the whole customizer).
- WebClient gate is literally `f8a.common.webclient.enabled` (no hyphen) while the tuning block binds under `f8a.common.web-client.*` — relaxed binding accepts both spellings for the same `webClient` field.
- Proxy is enabled by default but a no-op unless JVM proxy system properties are set (`use-system-properties=true`); set `use-system-properties=false` to use explicit `host`/`port`.
- Every Summer bean is `@ConditionalOnMissingBean` — override by declaring your own: `SummerGlobalExceptionHandler`, `SummerServletExceptionHandler`, `WebClientBuilderFactory`, `RequestInfoWebFilter`, `OpenAPI`, `OpenApiCustomizer`.
- `SummerWebfluxConfiguration` is ungated (not under `f8a.common.enabled`) — its `RequestInfoWebFilter` + `Txid`/`Ufid` formatters are always on in a WebFlux app.
- `EnableAllAutoConfig` only activates if `org.springframework.boot.autoconfigure.SpringBootApplication` is on the classpath (`@ConditionalOnClass` on `SummerRestAutoConfiguration`).
- `SummerApiDocAutoConfiguration` needs springdoc on the classpath (`summer-rest-common` brings `springdoc-openapi-starter-webflux-ui`); `SpringDocPropertyCustomizer` bean is additionally `@ConditionalOnClass(org.springdoc.core.properties.SpringDocConfigProperties)`.

## Graph refs
- `class:rest/rest-autoconfigure/src/main/java/io/f8a/summer/core/autoconfigure/SummerRestAutoConfiguration.java:SummerRestAutoConfiguration` — `rest/rest-autoconfigure/src/main/java/io/f8a/summer/core/autoconfigure/SummerRestAutoConfiguration.java`
- `class:rest/rest-autoconfigure/src/main/java/io/f8a/summer/core/autoconfigure/JacksonAutoConfiguration.java:JacksonAutoConfiguration` — `rest/rest-autoconfigure/src/main/java/io/f8a/summer/core/autoconfigure/JacksonAutoConfiguration.java`
- `class:rest/rest-autoconfigure/src/main/java/io/f8a/summer/core/autoconfigure/SummerWebfluxConfiguration.java:SummerWebfluxConfiguration` — `rest/rest-autoconfigure/src/main/java/io/f8a/summer/core/autoconfigure/SummerWebfluxConfiguration.java`
- `class:rest/rest-autoconfigure/src/main/java/io/f8a/summer/core/autoconfigure/SummerApiDocAutoConfiguration.java:SummerApiDocAutoConfiguration` — `rest/rest-autoconfigure/src/main/java/io/f8a/summer/core/autoconfigure/SummerApiDocAutoConfiguration.java`
- `file:rest/rest-autoconfigure/src/main/resources/META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports`
- `class:rest/rest-common/src/main/java/io/f8a/summer/rest/common/exception/SummerGlobalExceptionHandler.java:SummerGlobalExceptionHandler` — `rest/rest-common/src/main/java/io/f8a/summer/rest/common/exception/SummerGlobalExceptionHandler.java`
- `class:rest/rest-common/src/main/java/io/f8a/summer/rest/common/exception/SummerServletExceptionHandler.java:SummerServletExceptionHandler` — `rest/rest-common/src/main/java/io/f8a/summer/rest/common/exception/SummerServletExceptionHandler.java`
- `class:rest/rest-common/src/main/java/io/f8a/summer/rest/common/apidoc/ApiDocController.java:ApiDocController` — `rest/rest-common/src/main/java/io/f8a/summer/rest/common/apidoc/ApiDocController.java`
- `class:rest/rest-common/src/main/java/io/f8a/summer/rest/common/apidoc/SpringDocPropertyCustomizer.java:SpringDocPropertyCustomizer` — `rest/rest-common/src/main/java/io/f8a/summer/rest/common/apidoc/SpringDocPropertyCustomizer.java`
- `class:core/src/main/java/io/f8a/summer/core/autoconfigure/CommonLibProperties.java:CommonLibProperties` — `core/src/main/java/io/f8a/summer/core/autoconfigure/CommonLibProperties.java` (`f8a.common.*`)
- `file:core/src/main/java/io/f8a/summer/core/logging/HttpLoggingProperties.java` — `core/src/main/java/io/f8a/summer/core/logging/HttpLoggingProperties.java` (`summer.http.logging.*`)
- `class:core/src/main/java/io/f8a/summer/core/webclient/WebClientBuilderFactory.java:WebClientBuilderFactory` — `core/src/main/java/io/f8a/summer/core/webclient/WebClientBuilderFactory.java` (see core.md)
