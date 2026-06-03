---
id: rules/security/actuator
paths:
  - "**/application*.properties"
  - "**/application*.yml"
severity: high
tags: [actuator, spring-boot, exposure]
---
<!-- ClaudeHut rule template — generated into .claude/rules/security/actuator.md by claudehut-init. Reused & enhanced from committed rules/security/actuator.md. -->


# Spring Boot Actuator — Safe Exposure

## Defaults

Spring Boot Actuator exposes management endpoints (`/actuator/*`). Several are sensitive:
- `/env` — application config (may include credentials).
- `/heapdump` — full JVM memory dump.
- `/threaddump` — running thread state.
- `/loggers` — runtime log level change.
- `/configprops` — all `@ConfigurationProperties`.
- `/beans` — full bean graph.

Only `/health` and `/info` are safe to expose publicly (and even those may leak info).

## DO

```yaml
management:
  endpoints:
    web:
      exposure:
        include: health,info,metrics
        exclude: env,heapdump,threaddump,beans,configprops
      base-path: /actuator
  endpoint:
    health:
      show-details: when_authorized      # not "always"
      show-components: when_authorized
    info:
      enabled: true
```

## Auth for sensitive endpoints

```java
@Bean
public SecurityFilterChain actuatorChain(HttpSecurity http) throws Exception {
    return http
        .securityMatcher(EndpointRequest.toAnyEndpoint().excluding(HealthEndpoint.class, InfoEndpoint.class))
        .authorizeHttpRequests(auth -> auth.anyRequest().hasRole("ADMIN"))
        .httpBasic(Customizer.withDefaults())
        .build();
}
```

Or specific:

```java
.authorizeHttpRequests(auth -> auth
    .requestMatchers("/actuator/health", "/actuator/info").permitAll()
    .requestMatchers("/actuator/**").hasRole("ADMIN"))
```

## DON'T

```yaml
# NEVER
management:
  endpoints:
    web:
      exposure:
        include: '*'                     # ← exposes everything
  endpoint:
    health:
      show-details: always               # ← leaks DB host, queue names
```

## Prometheus metrics

`/actuator/prometheus` — generally OK to expose to monitoring scraper (Prometheus). But verify:
- Network policy restricts to monitoring namespace.
- No sensitive data in metric labels.

## info endpoint

`info.*` is what you put in:

```yaml
info:
  app:
    name: ${spring.application.name}
    version: @project.version@
    build: @build.number@
  # NEVER:
  # secret: ${some.secret}
```

## Health probe details

When `show-details: when_authorized`:
- Unauthenticated → `{"status":"UP"}` — minimal.
- Authenticated admin → full details (DB connection, disk space, etc.).

## Custom health indicator

```java
@Component
public class KafkaHealthIndicator implements HealthIndicator {
    @Override
    public Health health() {
        try {
            // ping kafka
            return Health.up().build();
        } catch (Exception e) {
            return Health.down().withDetail("error", e.getMessage()).build();
            // Don't include connection string here
        }
    }
}
```

## Detection (Phase 5)

Regex flagged High:

```regex
management\.endpoints\.web\.exposure\.include[ =:]*\*
management\.endpoint\.health\.show-details[ =:]*always
```

## K8s probe paths

Liveness / readiness probes typically use `/actuator/health/liveness` and `/actuator/health/readiness`. These should respond without auth (Kubernetes can't auth):

```yaml
management:
  endpoint:
    health:
      probes:
        enabled: true
      group:
        liveness:
          include: livenessState
        readiness:
          include: readinessState,db,redis
```

Probes use simplified health groups — no internal details leaked.
