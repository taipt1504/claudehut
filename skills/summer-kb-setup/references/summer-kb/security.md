# security — summer-security-autoconfigure, summer-apisix-resource-server, summer-jwt-resource-server, summer-apikey-resource-server, summer-keycloak
> Consumer-facing: yes · Auto-config: default-on (apisix) · Depends on: core, rest

## TL;DR
- `summer-security-autoconfigure` (default-on) imports 3 auto-configs; inbound auth is **on by default** but does nothing until the consumer builds a `SecurityWebFilterChain` and applies the framework `Customizer` beans.
- `f8a.security.apisix.resource-server.providers.*` MUST be non-empty (≥1 provider with `server-url`+`realm`) or the context fails at startup.
- `ReactiveKeycloakClient`, the API-key filter, and `ReactiveAuthenticationServiceImpl` are **manual** — no autoconfig registers them.

## Activate
Gradle: `implementation "io.f8a.summer:summer-security-autoconfigure"` (group `io.f8a.summer`; `api`-exposes jwt + apisix + keycloak + `spring-boot-starter-security`). Registered in `security-autoconfigure/.../META-INF/spring/…AutoConfiguration.imports` (order below).

| Auto-config (import order) | Gate | Default |
|---|---|---|
| `ReactiveApisixResourceServerAutoConfiguration` | `f8a.security.apisix.resource-server.enabled=true` (`matchIfMissing`) + `@ConditionalOnClass(EnableWebFluxSecurity)` + `@ConditionalOnWebApplication(REACTIVE)` | on |
| `ReactiveApisixKeycloakAdminAutoConfiguration` | `f8a.security.apisix.resource-server.enabled=true` (`matchIfMissing`) only; `@AutoConfiguration(before=…ResourceServer…)` + `@AutoConfigureAfter(RedisReactiveAutoConfiguration)` | on |
| `ReactiveBaseResourceServerAutoConfiguration` | **no property gate** — `@ConditionalOnClass(EnableWebFluxSecurity)` + `@ConditionalOnWebApplication(REACTIVE)` | on in any reactive app |

Note: `summer-jwt-resource-server` + `summer-keycloak` come transitively via the `api` deps above — but no autoconfig registers a consumer-injectable `ReactiveKeycloakClient` bean (construct it manually). `summer-apikey-resource-server` is a separate dep (not pulled in) with no autoconfig.

## Config keys
`@ConfigurationProperties("f8a.security.apisix.resource-server")` → `ApisixResourceServerProperties`.

| Key | Default | Meaning |
|---|---|---|
| `.enabled` | `true` | gate for both apisix auto-configs |
| `.role-hierarchy` | `""` | Spring `RoleHierarchy` string; feeds method-security expression handler |
| `.providers.<id>.server-url` | — (required) | Keycloak base URL; seeds issuer + Admin API host |
| `.providers.<id>.realm` | — (required) | realm; part of derived issuer |
| `.providers.<id>.issuer-uri` | `serverUrl+"/realms/"+realm` | explicit `iss` when public URL ≠ `server-url` |
| `.providers.<id>.client-id` / `.client-secret` | — | required iff provider is `sync-role` target or `group-role-authorization=true` |
| `.providers.<id>.group-role-authorization` | `false` | true → tokens from this iss resolve group→roles via Admin API |
| `.sync-role` | null/blank → off | provider id to run `@AuthRoles`→Keycloak sync against |
| `.blacklist-prefix-key` | null/blank → off | Redis `<prefix>:<jti>` revocation check per request |
| `.group-role-authorization.claim-name` | `role_groups` | JWT claim holding group paths |
| `.group-role-authorization.l1.ttl` | `60s` | in-memory cache TTL |
| `.group-role-authorization.l2.ttl` | `5m` | Redis L2 cache TTL (block absent → L1-only) |
| `.group-role-authorization.l2.key-prefix` | `auth-group-role:` | L2 Redis key prefix |
| `.group-role-authorization.l2.invalidation-channel` | `group-role-changes` | Redis pub/sub channel for cache invalidation |

## Public API
| Type | When to use | Node id |
|---|---|---|
| `ReactiveApisixCustomizer` (bean) | apply in your `SecurityWebFilterChain` to add the bearer `AuthenticationWebFilter` (at `AUTHENTICATION` order) | class:security/security-autoconfigure/src/main/java/io/f8a/summer/autoconfigure/security/apisix/resource/reactive/ReactiveApisixCustomizer.java:ReactiveApisixCustomizer |
| `ReactiveSummerHttpSecurityCustomizer` (bean) | apply first in the chain for CORS, CSRF-off, NoOp context repo, error writers | class:security/security-autoconfigure/src/main/java/io/f8a/summer/autoconfigure/security/base/resource/reactive/ReactiveSummerHttpSecurityCustomizer.java:ReactiveSummerHttpSecurityCustomizer |
| `ApisixResourceServerProperties` | reference for every config key above | class:security/apisix-resource-server/src/main/java/io/f8a/summer/autoconfigure/security/apisix/resource/ApisixResourceServerProperties.java:ApisixResourceServerProperties |
| `ReactiveAuthenticationService` / `…Impl` | read current principal in a Service (declare `…Impl` as a `@Bean` yourself) | class:security/jwt-resource-server/src/main/java/io/f8a/summer/security/authentication/ReactiveAuthenticationService.java:ReactiveAuthenticationService |
| `DefaultUserDetail` / `DefaultAuthentication` | principal + `Authentication` types resolved from the token | class:security/jwt-resource-server/src/main/java/io/f8a/summer/security/common/DefaultUserDetail.java:DefaultUserDetail |
| `ClaimKeys` | claim-name constants when reading claims | class:security/jwt-resource-server/src/main/java/io/f8a/summer/security/authentication/ClaimKeys.java:ClaimKeys |
| `SseAuthCustomizer` | opt-in bean to allow JWT via `?token=` on SSE paths (binds predicate→provider id) | file:security/security-autoconfigure/src/main/java/io/f8a/summer/autoconfigure/security/apisix/resource/reactive/SseAuthCustomizer.java |
| `JwtBlacklistChecker` | override the default Redis blacklist (`@ConditionalOnMissingBean`) | class:security/security-autoconfigure/src/main/java/io/f8a/summer/autoconfigure/security/apisix/resource/reactive/ReactiveApisixResourceServerAutoConfiguration.java:ReactiveApisixResourceServerAutoConfiguration |
| `ReactiveKeycloakClient` (+ `KeycloakConfig`) | manual Admin REST facade: `realm()`,`tokenResource()`,`users()`,`clients()`,`groups()` | class:security/keycloak/src/main/java/io/f8a/summer/keycloak/ReactiveKeycloakClient.java:ReactiveKeycloakClient |
| `ReactiveApiKeyWebFilter` | manual `WebFilter` (`@Order(-90)`, reads `x-api-key`, optional IP allowlist) | class:security/apikey-resource-server/src/main/java/io/f8a/summer/security/common/ReactiveApiKeyWebFilter.java:ReactiveApiKeyWebFilter |
| `@AuthRoles` / `@ResourceDef` / `@FeatureDef` | declare roles for sync (annotations live in `summer-core`) | class:core/src/main/java/io/f8a/summer/security/AuthRoles.java:AuthRoles |

## Usage
```yaml
f8a.security.apisix.resource-server:
  sync-role: primary                      # blank = no @AuthRoles→Keycloak sync
  providers:
    primary:
      server-url: http://keycloak.internal:8080
      realm: f8a
      client-id: ${KC_CLIENT_ID}
      client-secret: ${KC_CLIENT_SECRET}
      group-role-authorization: true      # needs client-id + client-secret
```
```java
@Bean
SecurityWebFilterChain security(ServerHttpSecurity http,
    ReactiveSummerHttpSecurityCustomizer base, ReactiveApisixCustomizer apisix) {
  base.customize(http);      // CORS, CSRF off, error writers
  apisix.customize(http);    // bearer AuthenticationWebFilter
  return http.authorizeExchange(e -> e
      .pathMatchers("/actuator/**").permitAll().anyExchange().authenticated()).build();
}
```

## Gotchas
- Customizers are beans, NOT a wired chain — no `SecurityWebFilterChain` is auto-registered; without the consumer bean above, inbound auth is inert.
- `providers` empty → `multiRealmAuthenticationConverter` throws `IllegalStateException` at startup; each provider needs `server-url`+`realm`; duplicate resolved `issuerUri()` across providers also throws.
- `group-role-authorization=true` requires that provider's `client-id`+`client-secret` (throws otherwise); providers without it use `UserInfoAuthenticationConverter` (reads `resource_access`, no network call).
- `sync-role` must name a provider that has admin credentials; the sync bean is gated by `@ConditionalOnExpression` on a non-blank `sync-role` (blank/absent → no sync).
- Role-string parsing splits on the FIRST `:` (`RoleDefinitionScanner`): `compliance:report-simo:view` → resource `compliance`, role `report-simo:view`; `@ResourceDef(code=...)` MUST equal segment 1 or the field is skipped; only `public static final String` fields scanned. Follow the 7-permission api-roles rule.
- `blacklist-prefix-key` set but no `ReactiveStringRedisTemplate` on context → startup throws; override via a `JwtBlacklistChecker` bean.
- Group-role L2 listener/publisher (`groupRoleInvalidationListener`, `GroupRoleInvalidator`) are gated ONLY by `@ConditionalOnBean(ReactiveRedisConnectionFactory)` — there is NO `@ConditionalOnProperty` on `invalidation-channel` despite the javadoc; a Redis factory present with the `l2` block absent → NPE at startup (`getL2()` is null).
- `ReactiveAuthenticationServiceImpl` has no `@Component` and is in no autoconfig — declare it as a `@Bean`; `getAuthentication()` returns empty on non-`DefaultAuthentication` context.
- `DefaultUserDetail.getAuthorities()` prefixes every `realm_access`/`resource_access` role with `ROLE_` and upper-cases it (empty → single `ROLE_ANONYMOUS`); gate with `hasAnyRole(@roles.X)` SpEL, never raw strings.
- `@AuthRoles`/`@ResourceDef`/`@FeatureDef` live in `summer-core`, not this module.

## Graph refs
- file:security/security-autoconfigure/src/main/resources/META-INF/spring/org.springframework.boot.autoconfigure.AutoConfiguration.imports
- class:security/security-autoconfigure/src/main/java/io/f8a/summer/autoconfigure/security/apisix/resource/reactive/ReactiveApisixResourceServerAutoConfiguration.java:ReactiveApisixResourceServerAutoConfiguration
- class:security/security-autoconfigure/src/main/java/io/f8a/summer/autoconfigure/security/apisix/resource/reactive/ReactiveApisixKeycloakAdminAutoConfiguration.java:ReactiveApisixKeycloakAdminAutoConfiguration
- class:security/security-autoconfigure/src/main/java/io/f8a/summer/autoconfigure/security/base/resource/reactive/ReactiveBaseResourceServerAutoConfiguration.java:ReactiveBaseResourceServerAutoConfiguration
- class:security/apisix-resource-server/src/main/java/io/f8a/summer/autoconfigure/security/apisix/resource/ApisixResourceServerProperties.java:ApisixResourceServerProperties
- class:security/security-autoconfigure/src/main/java/io/f8a/summer/autoconfigure/security/apisix/resource/reactive/ReactiveApisixCustomizer.java:ReactiveApisixCustomizer
- class:security/security-autoconfigure/src/main/java/io/f8a/summer/autoconfigure/security/base/resource/reactive/ReactiveSummerHttpSecurityCustomizer.java:ReactiveSummerHttpSecurityCustomizer
- class:security/jwt-resource-server/src/main/java/io/f8a/summer/security/authentication/ReactiveAuthenticationService.java:ReactiveAuthenticationService
- class:security/jwt-resource-server/src/main/java/io/f8a/summer/security/authentication/ReactiveAuthenticationServiceImpl.java:ReactiveAuthenticationServiceImpl
- class:security/jwt-resource-server/src/main/java/io/f8a/summer/security/authentication/ClaimKeys.java:ClaimKeys
- class:security/jwt-resource-server/src/main/java/io/f8a/summer/security/common/DefaultUserDetail.java:DefaultUserDetail
- class:security/keycloak/src/main/java/io/f8a/summer/keycloak/ReactiveKeycloakClient.java:ReactiveKeycloakClient
- class:security/keycloak/src/main/java/io/f8a/summer/keycloak/synchronizer/RoleDefinitionScanner.java:RoleDefinitionScanner
- class:security/keycloak/src/main/java/io/f8a/summer/keycloak/synchronizer/KeycloakRoleSynchronizer.java:KeycloakRoleSynchronizer
- class:security/apikey-resource-server/src/main/java/io/f8a/summer/security/common/ReactiveApiKeyWebFilter.java:ReactiveApiKeyWebFilter
- class:core/src/main/java/io/f8a/summer/security/AuthRoles.java:AuthRoles
- class:core/src/main/java/io/f8a/summer/security/ResourceDef.java:ResourceDef
- class:core/src/main/java/io/f8a/summer/security/FeatureDef.java:FeatureDef
</content>
</invoke>
