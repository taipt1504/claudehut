# platform — summer-platform
> Consumer-facing: yes · Auto-config: BOM · Depends on: none (BOM aggregates all modules)

## TL;DR
- Gradle `java-platform` BOM (zero Java sources); its only artifact is the Maven BOM publication.
- Pins every `summer-*` module to the release `version` (0.3.10) and re-exports Spring Boot / Jackson / springdoc / Debezium / Keycloak / Swagger version constraints.
- `summer-payment-sdk` is pinned separately to `paymentSdkVersion` (0.3.26), overridable by consumers.

## Activate
| | |
|---|---|
| Gradle coordinate | `implementation platform('io.f8a.summer:summer-platform:0.3.10')` |
| AutoConfiguration | None — BOM, no runtime code |
| Gate property | None — importing the platform adds no dependencies, only version constraints |

## Config keys
None — types/utilities only.

## Public API
None. summer-platform exposes no classes/annotations/interfaces — its only surface is the Maven BOM publication (`mavenJava` from `components.javaPlatform`). After importing it, declare these constrained coordinates version-less: `summer-core`, `summer-rest-autoconfigure`, `summer-rest-common`, `summer-data-autoconfigure`, `summer-data-r2dbc`, `summer-data-audit(-autoconfigure)`, `summer-data-outbox(-autoconfigure)`, `summer-apisix-resource-server`, `summer-keycloak`, `summer-security-autoconfigure`, `summer-jwt-resource-server`, `summer-apikey-resource-server`, `summer-ratelimit-core`, `summer-ratelimit-autoconfigure`, `summer-kafka-consumer(-autoconfigure)`, `summer-file`, `summer-test`, `summer-payment-sdk`.

## Usage
```gradle
dependencies {
    implementation platform('io.f8a.summer:summer-platform:0.3.10')
    implementation 'io.f8a.summer:summer-rest-autoconfigure'   // no version
    testImplementation 'io.f8a.summer:summer-test'             // no version
}
```
Requires the GitLab Maven repo configured with `GITLAB_TOKEN` (see repo README `repositories {}`).

## Gotchas
- BOM only: importing it pulls in **no** dependencies — you must still declare each `summer-*` artifact; the BOM just supplies the version.
- `summer-payment-sdk` is NOT aligned to the platform `version`; it is pinned to `paymentSdkVersion` (0.3.26) and intended to be overridable for a newer SDK.
- Uses `javaPlatform { allowDependencies() }` to import other platforms (`spring-boot-dependencies`, `jackson-bom`, `springdoc-openapi-bom`) — their transitive version pins come along; `spring-tx` / `spring-kafka` versions are managed by `spring-boot-dependencies`.
- Also pins third-party libs directly: Debezium (api/embedded/postgres-connector/kafka-storage), keycloak-admin-client, swagger (annotations/core/models).
- Access requires the private GitLab Maven repo + token; without `GITLAB_TOKEN`, resolution fails.
- No runtime behavior, no conditional properties, nothing to enable/disable.

## Graph refs
- `config:platform/build.gradle` — the BOM definition (`java-platform` plugin, `constraints {}`, `mavenJava` publication). This is the module's only graph node (type `config`, NOT `file:`).
- No `file`/`class`/autoconfig nodes exist — the module ships no Java sources.
